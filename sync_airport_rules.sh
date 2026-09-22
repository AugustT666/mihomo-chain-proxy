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
#   目标混合**（实测为 代理/DIRECT/REJECT 三种）。若走 RULE-SET，160 条 DIRECT 和 27 条
#   REJECT 会被错误地送进代理。故必须逐条内联，且**严格保持原顺序**。
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
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

VARS="${VARS:-$BASE/vars.env}"

# 机场策略组名 → 本项目策略组名
#
# 映射表来自 vars.env 的 AIRPORT_GROUP_MAP（格式 `机场组=本项目组`，逗号分隔多项），
# **刻意不写死在代码里**：
#   1) 脱敏——本仓库是公开的，写死等于公开你用的是哪家机场；
#   2) 换机场时只改 vars.env 一行，不必动代码。
# 机场的主 select 组通常承载它绝大多数规则（本项目实测 515 条里有 328 条指向它）。
#
# 若未设置，后续校验会因"目标不在已知策略组内"而报错退出——这是刻意的：
# 宁可中止，也不要把规则静默指向一个不存在的组（那会让 mihomo 拒绝整份配置）。
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
            *)   echo "[sync-rules] WARN: AIRPORT_GROUP_MAP 条目缺少 '=': $_p" >&2 ;;
        esac
    done
fi

# 本项目允许出现的规则目标（重写后若出现别的，说明映射不全 → 报错退出）
ALLOWED_TARGETS="Proxy DIRECT REJECT REJECT-DROP PASS"

log() { echo "[sync-rules] $*"; }
die() { echo "[sync-rules] ERROR: $*" >&2; exit 1; }

[ -f "$SRC" ] || die "找不到机场配置文件: $SRC"
if [ "${#GROUP_MAP[@]}" -eq 0 ]; then
    log "WARN: AIRPORT_GROUP_MAP 未设置（vars.env 里加一行，如 机场主组名=Proxy）"
    log "      规则里引用的机场策略组将被判定为未知目标并导致校验失败"
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

# ── 2. 逐条重写目标 ──
#    三字段规则格式: 类型,内容,目标[,附加参数]
#    目标恒为第 3 个逗号分隔字段。去掉引号；丢弃终结的 MATCH（兜底由本项目自己给）。
REWRITTEN=$(
  printf '%s\n' "$RAW" | while IFS= read -r r; do
      r="${r%\"}"; r="${r#\"}"; r="${r%\'}"; r="${r#\'}"     # 去首尾引号
      [ -z "$r" ] && continue
      TYPE="${r%%,*}"
      [ "$TYPE" = "MATCH" ] && continue                       # 丢弃终结规则
      # 拆成前两段 + 剩余
      REST="${r#*,}"; PAYLOAD="${REST%%,*}"
      if [ "$REST" = "$PAYLOAD" ]; then
          # 只有两段，没有目标 —— 机场不该有这种，跳过并记录
          echo "!!NOSKIP!! $r" >&2
          continue
      fi
      TAIL="${REST#*,}"; TARGET="${TAIL%%,*}"; EXTRA=""
      [ "$TAIL" != "$TARGET" ] && EXTRA=",${TAIL#*,}"
      # 组名重写
      if [ -n "${GROUP_MAP[$TARGET]:-}" ]; then TARGET="${GROUP_MAP[$TARGET]}"; fi
      # 注意：缩进必须与 config.template.yaml 里 rules 段一致（第 0 列）。
      # 同一 YAML 序列里混用缩进会直接导致配置非法。
      printf -- "- '%s,%s,%s%s'\n" "$TYPE" "$PAYLOAD" "$TARGET" "$EXTRA"
  done
)

SKIPPED=$(printf '%s\n' "$RAW" | sed "s/^['\"]//; s/['\"]$//" | grep -c '^MATCH,' || true)
KEPT=$(printf '%s\n' "$REWRITTEN" | grep -c .)
log "丢弃终结规则 $SKIPPED 条；保留 $KEPT 条"

# ── 3. 校验：目标必须全部落在本项目已知的策略组/内置动作内 ──
BAD=$(printf '%s\n' "$REWRITTEN" | sed "s/^  - '//; s/'$//" | awk -F',' '{print $3}' | sort -u |
      grep -vxF -e Proxy -e DIRECT -e REJECT -e REJECT-DROP -e PASS || true)
if [ -n "$BAD" ]; then
    die "以下规则目标不在已知策略组内（需要补 GROUP_MAP 映射）:
$(printf '%s\n' "$BAD" | sed 's/^/    /')"
fi

# ── 4. 合理性闸门：规则数骤降说明抽取坏了，绝不覆盖 ──
MIN=200
if [ "$KEPT" -lt "$MIN" ]; then
    die "只保留 $KEPT 条（少于阈值 $MIN），疑似抽取失败——不写盘，保留旧文件"
fi

log "目标分布（重写后）:"
printf '%s\n' "$REWRITTEN" | sed "s/^  - '//; s/'$//" | awk -F',' '{print $3}' | sort | uniq -c |
  sed 's/^/[sync-rules]   /'

if [ "$CHECK" = 1 ]; then
    log "--check 模式，不写盘。预览前 5 条:"
    printf '%s\n' "$REWRITTEN" | head -5 | sed 's/^/[sync-rules]   /'
    exit 0
fi

# ── 5. 落盘（保权限，原子替换）──
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
