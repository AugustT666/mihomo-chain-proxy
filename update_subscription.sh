#!/bin/bash
# Mihomo 配置应用脚本
#
# 执行顺序很重要（2026-09-22 调整，原顺序会让机场规则慢一个周期）：
#   1. 读取并校验 vars.env
#   2. 刷新机场订阅（PUT provider）—— 必须先做，下一步抽规则才读到最新内容
#   3. 同步机场规则（sync_airport_rules.sh → airport_rules.inc）
#   4. 渲染 config.template.yaml，并把机场规则注入 # @@AIRPORT_RULES@@ 标记处
#   5. **校验渲染结果**——专防"envsubst 静默产生空值"这类事故（2026-09-22 实际踩过）
#   6. 与现有 config.yaml 比对，有变化才写盘 + 热重载
#
# 可手动运行；NAS 上由 cron 每小时调用：
#   0 * * * * /vol1/mihomo/update_subscription.sh >> /tmp/mihomo_update.log 2>&1
#
# 注：节点测速由 mihomo 按 config 里的 health-check 自行完成，本脚本不触发。

set -u

BASE="$(cd "$(dirname "$0")" && pwd)"
API="http://127.0.0.1:9090"
MARKER='# @@AIRPORT_RULES@@'
INC="$BASE/airport_rules.inc"

fail() { echo "ERROR: $*" >&2; exit 1; }
log()  { echo "$*"; }

echo "========== $(date '+%Y-%m-%d %H:%M:%S') 开始 =========="

# ── 1. 读取 vars.env（逐行解析，兼容 URL 中的 & 等特殊字符）──
while IFS='=' read -r key rest || [ -n "$key" ]; do
    [[ "$key" =~ ^[[:space:]]*# ]] && continue   # 跳过注释
    [[ -z "${key// }" ]] && continue             # 跳过空行
    key="${key// }"
    export "$key=$rest"
done < "$BASE/vars.env"

for var in SUBSCRIBE_URL EXIT_SERVER EXIT_PORT EXIT_USER EXIT_PASS API_SECRET PROXY_DNS; do
    [ -n "${!var:-}" ] || fail "vars.env 缺少 $var（或值为空）"
done

# ── 2. 先刷新机场订阅，后面的规则抽取才读到最新内容 ──
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    "$API/providers/proxies/lelian_proxies" \
    -H "Authorization: Bearer $API_SECRET")
if [ "$CODE" = "204" ]; then
    log "✓ 订阅节点已刷新"
else
    log "⚠ 订阅刷新返回 HTTP $CODE（继续，沿用现有缓存）"
fi

# ── 3. 同步机场规则 ──
if [ -x "$BASE/sync_airport_rules.sh" ]; then
    if ! "$BASE/sync_airport_rules.sh"; then
        log "⚠ 机场规则同步失败 —— 沿用旧 airport_rules.inc（不会中断本次渲染）"
    fi
else
    log "⚠ 找不到 sync_airport_rules.sh，跳过机场规则同步"
fi

# ── 4. 渲染模板 + 注入机场规则 ──
NEW=$(envsubst '${SUBSCRIBE_URL}${EXIT_SERVER}${EXIT_PORT}${EXIT_USER}${EXIT_PASS}${API_SECRET}${PROXY_DNS}' \
      < "$BASE/config.template.yaml") || fail "envsubst 执行失败"

if [ -s "$INC" ]; then
    NEW=$(printf '%s\n' "$NEW" | awk -v inc="$INC" -v m="$MARKER" '
        index($0, m) { while ((getline l < inc) > 0) print l; close(inc); next }
        { print }') || fail "注入机场规则失败"
    log "✓ 已注入机场规则 $(grep -c . "$INC") 行"
else
    log "⚠ $INC 不存在或为空 —— 本次渲染不含机场规则（段 4 的国内直连仍会兜底）"
fi

# ── 5. 校验渲染结果 ──
#     这是对 2026-09-22 那次事故的直接防线：当时裸 envsubst 把 server/port/
#     username/password/url/secret 全渲染成空值，配置看着正常但代理链是断的。
printf '%s\n' "$NEW" | grep -q '\${' && fail "渲染后仍残留 \${...} 占位符，检查 config.template.yaml"

check_field() {   # $1=描述  $2=grep 正则
    printf '%s\n' "$NEW" | grep -q "$2" || fail "渲染结果中 $1 缺失或为空 —— 检查 vars.env 是否有空值"
}
check_field "出口服务器 (server:)"        '^  server: .\+'
check_field "出口端口 (port:)"            '^  port: [0-9]\+'
check_field "API 密钥 (secret:)"          '^secret: .\+'
check_field "订阅链接 (proxy-providers url:)" '^    url: "http.\+"'
check_field "代理解析器 (proxy-server-nameserver)" '^  - https\?://.\+'
log "✓ 关键字段校验通过（均非空）"

# YAML 解析闸门 —— 最关键的一道。
# 写盘发生在热重载【之前】，所以一旦把解析不了的配置写下去，它就会留在磁盘上；
# 若此后容器再重启，mihomo 会因读不懂配置而直接起不来（crash loop）。
# 2026-09-22 实际发生过：注入的机场规则用了 2 空格缩进，而模板 rules 段在第 0 列，
# 同一序列缩进混用 → YAML 非法 → 热重载 HTTP 400，但坏配置已经落盘。
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    if ! printf '%s\n' "$NEW" | python3 -c 'import sys,yaml; yaml.safe_load(sys.stdin)' 2>/tmp/yaml_err.$$; then
        err=$(head -3 /tmp/yaml_err.$$ | tr '\n' ' '); rm -f /tmp/yaml_err.$$
        fail "渲染结果不是合法 YAML，已阻止写盘（config.yaml 保持原样）。解析器报: $err"
    fi
    rm -f /tmp/yaml_err.$$
    log "✓ YAML 语法校验通过（rules $(printf '%s\n' "$NEW" | awk '/^rules:/{f=1;next} f&&/^- /{n++} END{print n+0}') 条）"
else
    log "⚠ 无 python3/PyYAML，跳过 YAML 语法校验"
fi

# ── 6. 有变化才写盘 + 热重载（失败自动回滚）──
#
# 两个必须守住的点：
#
#  (a) 写盘必须在重载【之前】——mihomo 是从磁盘读这份文件的。于是若重载失败，
#      磁盘上就留下一份 mihomo 读不懂的配置，容器下次重启会直接 crash loop。
#      所以失败时要把旧内容写回去。
#      2026-09-22 实际踩过：缩进错误导致 HTTP 400，坏配置已经落盘。
#
#  (b) 必须【原地写入】(`cat tmp > file`)，绝不能用 `mv`。
#      config.yaml 是以**单文件** bind mount 方式挂进容器的
#      (docker-compose.yml 里 `.../config.yaml:/root/.config/mihomo/config.yaml`)。
#      `mv` 会换掉 inode，而 bind mount 绑的是原 inode —— 容器侧将永远看不到更新。
#      （dns-select.sh 里同样的写法，也是这个原因。）
OLD=$(cat "$BASE/config.yaml" 2>/dev/null || true)

if [ "$NEW" != "$OLD" ]; then
    log "检测到配置变更，更新 config.yaml..."
    printf '%s\n' "$NEW" > "$BASE/config.yaml"
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$API/configs" \
        -H "Authorization: Bearer $API_SECRET" -H "Content-Type: application/json" \
        -d '{"path":"/root/.config/mihomo/config.yaml","force":false}')
    if [ "$CODE" = "204" ]; then
        log "✓ 热重载成功"
    else
        log "✗ 热重载失败 (HTTP $CODE) —— 正在回滚 config.yaml"
        if [ -n "$OLD" ]; then
            printf '%s\n' "$OLD" > "$BASE/config.yaml"
            log "  已回滚：磁盘配置与 mihomo 内存中的配置重新一致"
        else
            log "  ⚠ 没有旧配置可回滚"
        fi
        fail "热重载失败，本次改动未生效（config.yaml 已还原）"
    fi
else
    log "配置无变化，跳过重载"
fi

echo "========== 完成 =========="
