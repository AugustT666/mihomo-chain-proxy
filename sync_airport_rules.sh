#!/bin/bash
# sync_airport_rules.sh — 把机场订阅自带的 rules 捞出来，重写策略组名，
#                         生成 airport_rules.inc 供 config.template.yaml 注入。
#
# 为什么需要这个脚本：
#   机场订阅本身是一份**完整 Clash 配置**（含 500+ 条 rules、它自己的 dns/
#   proxy-groups）。但本项目以 `proxy-provider` 方式引用它，而 mihomo 对
#   provider 文件**只读 `proxies:` 段**——rules/dns/proxy-groups 全部丢弃。
#   于是本项目只剩 config.template.yaml 里手写的那几条规则，
#   机场精心维护的规则集（广告拦截 REJECT、流媒体分流、国内直连…）全被浪费。
#
# 为什么不能直接用 rule-providers：
#   官方文档里 classical 规则集是**两字段**格式（`DOMAIN-SUFFIX,google.com`），
#   目标由主配置的 `RULE-SET,name,target` 统一指定。而机场规则是**三字段、
#   目标混合**（实测为 代理/DIRECT/REJECT 三种）。若走 RULE-SET，非代理目标的
#   那些规则会被错误地送进代理。故必须逐条内联，且**严格保持原顺序**。
#
# 安全模型（重要）：
#   **规则来自远端订阅，是不可信输入。** 本脚本按此前提设计：
#     1) 规则类型只允许 [A-Z0-9-]；
#     2) 目标必须在已知策略组/内置动作白名单内，未知目标【逐条跳过】而非中止；
#     3) 写入 YAML 时转义单引号（否则一个 ' 就能撑破引号边界 → 配置注入）；
#     4) 产出片段要过一遍 YAML 解析自检；
#     5) 跳过比例异常（>5%）视为订阅格式变化或被篡改 → 中止不写盘。
#
# 输入: proxy_provider/lelian_proxies.yaml  （mihomo 下载并缓存的机场配置）
# 输出: airport_rules.inc                   （可直接插入 YAML 的 rules 片段）
#
# 用法: ./sync_airport_rules.sh [--check]
#   --check  只报告不写盘

set -u

BASE="$(cd "$(dirname "$0")" && pwd)"
SRC="$BASE/proxy_provider/lelian_proxies.yaml"
OUT="$BASE/airport_rules.inc"
VARS="${VARS:-$BASE/vars.env}"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

# 本项目允许出现的规则目标（重写后若出现别的，该条规则会被跳过）
ALLOWED_TARGETS="Proxy DIRECT REJECT REJECT-DROP PASS"
is_allowed() { case " $ALLOWED_TARGETS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# 已知的 mihomo 规则类型。**必须白名单，光校验字符集不够**——
# 字符集合法的假类型（如 `1BADTYPE`）会被原样写进配置，而 mihomo 会因此
# 拒绝整份配置。这是对抗测试实测出来的。
# 若机场启用了新类型而被这里漏掉：该类型的规则会被跳过并告警；
# 跳过比例超过 5% 时脚本会中止不写盘（见下），届时把这个类型加进来即可。
ALLOWED_RULE_TYPES="DOMAIN DOMAIN-SUFFIX DOMAIN-KEYWORD DOMAIN-REGEX GEOSITE GEOIP \
IP-CIDR IP-CIDR6 IP-SUFFIX IP-ASN SRC-IP-CIDR SRC-PORT DST-PORT \
IN-PORT IN-TYPE IN-USER IN-NAME IN-PROCESS IN-USER-AGENT \
PROCESS-PATH PROCESS-PATH-REGEX PROCESS-NAME PROCESS-NAME-REGEX \
UID UID-RANGE NETWORK DSCP RULE-SET SUB-RULE AND OR NOT"
is_allowed_type() { case " $ALLOWED_RULE_TYPES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# 跳过比例上限（百分比）。超过则判定为订阅格式变化/被篡改，中止不写盘。
MAX_SKIP_PCT=5

log() { echo "[sync-rules] $*"; }
warn() { echo "[sync-rules] WARN: $*" >&2; }
die() { echo "[sync-rules] ERROR: $*" >&2; exit 1; }

# ── 0. 载入策略组映射 ──
# 机场策略组名 → 本项目策略组名。来自 vars.env 的 AIRPORT_GROUP_MAP
# （格式 `机场组=本项目组`，逗号分隔多项），**刻意不写死在代码里**：
#   1) 脱敏——本仓库是公开的，写死等于公开你用的是哪家机场；
#   2) 换机场时只改 vars.env 一行，不必动代码。
declare -A GROUP_MAP=()
_map_src="${AIRPORT_GROUP_MAP:-}"
if [ -z "$_map_src" ] && [ -f "$VARS" ]; then
    _map_src=$(sed -n 's/^AIRPORT_GROUP_MAP=//p' "$VARS" 2>/dev/null | head -1)
fi
if [ -n "$_map_src" ]; then
    IFS=',' read -r -a _pairs <<< "$_map_src"
    for _p in "${_pairs[@]}"; do
        [ -z "${_p// }" ] && continue
        case "$_p" in
            *=*) GROUP_MAP["${_p%%=*}"]="${_p#*=}" ;;
            *)   warn "AIRPORT_GROUP_MAP 条目缺少 '=': $_p" ;;
        esac
    done
fi
log "策略组映射: ${_map_src:-（未设置）}"

[ -f "$SRC" ] || die "找不到机场配置文件: $SRC"
if [ "${#GROUP_MAP[@]}" -eq 0 ]; then
    warn "AIRPORT_GROUP_MAP 未设置（在 vars.env 里加一行，如 机场主组名=Proxy）"
    warn "      规则里引用的机场策略组将全部被判为未知目标并跳过"
fi

# ── 1. 抽取 rules 段（保留原始顺序）──
RAW=$(awk '
    /^rules:[[:space:]]*$/ { f=1; next }
    f && /^[a-zA-Z_-]+:/   { exit }          # 遇到下一个顶级键就停
    f && /^[[:space:]]*-[[:space:]]/ { sub(/^[[:space:]]*-[[:space:]]*/, ""); print }
' "$SRC")
[ -n "$RAW" ] || die "在 $SRC 里没找到 rules 段（机场可能改了订阅格式）"

TOTAL=$(printf '%s\n' "$RAW" | grep -c .)
log "从机场配置抽到 $TOTAL 条规则"

# ── 2. 逐条校验 + 重写目标 ──
#    三字段规则格式: 类型,内容,目标[,附加参数]，目标恒为第 3 个逗号分隔字段。
# YAML 单引号标量里，字面单引号必须写成两个 —— 见文件头"安全模型"第 3 条。
yaml_escape() { local v=$1; printf '%s' "${v//\'/\'\'}"; }

SKIPLOG=$(mktemp) || die "无法创建临时文件"
trap 'rm -f "$SKIPLOG"' EXIT INT TERM

REWRITTEN=$(
  printf '%s\n' "$RAW" | while IFS= read -r r; do
      r="${r%\"}"; r="${r#\"}"; r="${r%\'}"; r="${r#\'}"     # 去首尾引号
      [ -z "$r" ] && continue

      TYPE="${r%%,*}"
      [ "$TYPE" = "MATCH" ] && continue                       # 丢弃终结规则
      if ! is_allowed_type "$TYPE"; then                      # 必须是已知规则类型
          warn "规则类型不在已知集合内，跳过: $(printf '%s' "$r" | cut -c1-60)"
          echo "type:$TYPE" >> "$SKIPLOG"; continue
      fi

      REST="${r#*,}"; PAYLOAD="${REST%%,*}"
      if [ "$REST" = "$PAYLOAD" ]; then                       # 只有两段，缺目标
          warn "规则缺少目标字段，跳过: $(printf '%s' "$r" | cut -c1-60)"
          echo "no-target" >> "$SKIPLOG"; continue
      fi
      TAIL="${REST#*,}"; TARGET="${TAIL%%,*}"; EXTRA=""
      [ "$TAIL" != "$TARGET" ] && EXTRA=",${TAIL#*,}"

      # 组名重写
      if [ -n "${GROUP_MAP[$TARGET]:-}" ]; then TARGET="${GROUP_MAP[$TARGET]}"; fi

      # 目标必须在白名单内。未知目标【跳过这条】而不是让整份失败 ——
      # 规则来自不可信订阅，一条畸形/恶意规则不应导致配置再也无法更新。
      if ! is_allowed "$TARGET"; then
          warn "目标不在已知策略组内，跳过: $TARGET"
          echo "$TARGET" >> "$SKIPLOG"; continue
      fi

      # 缩进必须与 config.template.yaml 的 rules 段一致（第 0 列）；
      # 同一 YAML 序列里混用缩进会直接导致配置非法。
      printf -- "- '%s,%s,%s%s'\n" \
          "$(yaml_escape "$TYPE")" "$(yaml_escape "$PAYLOAD")" \
          "$(yaml_escape "$TARGET")" "$(yaml_escape "$EXTRA")"
  done
)

# 用 awk 计数而不是 `grep -c .`：grep 在"零匹配"时输出 0 但**退出码为 1**，
# 配上 `|| echo 0` 会得到两行 "0\n0"，后续 `[ -gt ]` 直接报"需要整数表达式"。
KEPT=$(printf '%s\n' "$REWRITTEN" | awk 'END{print NR+0}')
SKIPPED=$(awk 'END{print NR+0}' "$SKIPLOG")
log "保留 $KEPT 条，跳过 $SKIPPED 条"

if [ "$SKIPPED" -gt 0 ]; then
    log "跳过原因分布:"
    sort "$SKIPLOG" | uniq -c | sed 's/^/[sync-rules]   /'
    # 跳过比例异常 → 订阅格式变了或被篡改，宁可中止也不要写一份残缺的规则集
    if [ "$TOTAL" -gt 0 ] && [ $((SKIPPED * 100)) -gt $((TOTAL * MAX_SKIP_PCT)) ]; then
        die "跳过比例过高（$SKIPPED/$TOTAL，上限 ${MAX_SKIP_PCT}%）——疑似订阅格式变化或被篡改，不写盘"
    fi
fi

# ── 3. 自检：产出片段本身必须是合法 YAML ──
# 对"远端不可信输入"的总闸：即使前面的校验有疏漏，也不让畸形片段落盘。
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    if ! { echo "rules:"; printf '%s\n' "$REWRITTEN"; } \
         | python3 -c 'import sys,yaml; yaml.safe_load(sys.stdin)' 2>/dev/null; then
        die "生成的规则片段不是合法 YAML（疑似含未转义引号或畸形规则）——不写盘"
    fi
    log "✓ 片段 YAML 自检通过"
fi

# ── 4. 合理性闸门：规则数骤降说明抽取坏了，绝不覆盖 ──
MIN=200
if [ "$KEPT" -lt "$MIN" ]; then
    die "只保留 $KEPT 条（少于阈值 $MIN），疑似抽取失败——不写盘，保留旧文件"
fi

log "目标分布（重写后）:"
printf '%s\n' "$REWRITTEN" | sed "s/^- '//; s/'$//" | awk -F',' '{print $3}' | sort | uniq -c |
  sed 's/^/[sync-rules]   /'

if [ "$CHECK" = 1 ]; then
    log "--check 模式，不写盘。预览前 5 条:"
    printf '%s\n' "$REWRITTEN" | head -5 | sed 's/^/[sync-rules]   /'
    exit 0
fi

# ── 5. 落盘（原地写入，保留权限）──
# 与本目录其它脚本一致：不用 mv，避免换掉 inode（config.yaml 系单文件 bind mount，
# 同理适用于这里的任何被挂载文件）。
TMP="$OUT.tmp.$$"
{
  echo "# ══ 以下 $(printf '%s' "$KEPT") 条由 sync_airport_rules.sh 自动生成 ══"
  echo "# 来源: proxy_provider/lelian_proxies.yaml（机场订阅，该文件不入库）"
  echo "# 组名已按 vars.env 的 AIRPORT_GROUP_MAP 重写；终结 MATCH 已丢弃（由模板末尾的 MATCH,Proxy 兜底）"
  echo "# 不要手改——要改请改 config.template.yaml，或改 vars.env 的 AIRPORT_GROUP_MAP"
  echo "# 缩进保持第 0 列，必须与 config.template.yaml 的 rules 段一致"
  echo "#"
  echo "# 注意: 规则【数据】里可能出现与机场品牌相关的目标域名。那是功能必需的——"
  echo "#       删掉它会改变该域名的分流行为，所以不做替换。品牌标识只应从注释与文档中消失。"
  printf '%s\n' "$REWRITTEN"
} > "$TMP"
cat "$TMP" > "$OUT" && rm -f "$TMP"
log "已写入 $OUT ($(grep -c . "$OUT") 行)"
