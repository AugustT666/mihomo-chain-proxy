#!/bin/bash
# Mihomo 配置应用脚本
#   1. 读取 vars.env → 用 envsubst 渲染 config.yaml
#   2. 有变更时热重载 mihomo
#   3. 刷新订阅节点（拉取机场最新节点列表）
# 可手动运行；也可挂 cron 定时（改完 vars.env 后自动生效）：
#   0 * * * * /path/to/update_subscription.sh >> /tmp/mihomo_update.log 2>&1
#
# 注：节点测速（健康检查）由 mihomo 自身按 config 里 health-check.interval 自动完成，
#     本脚本无需再手动触发。

BASE="$(cd "$(dirname "$0")" && pwd)"
API="http://127.0.0.1:9090"

echo "========== $(date '+%Y-%m-%d %H:%M:%S') 开始 =========="

# ── 1. 读取 vars.env（逐行解析，兼容 URL 中的 & 等特殊字符）──
while IFS='=' read -r key rest || [ -n "$key" ]; do
    [[ "$key" =~ ^[[:space:]]*# ]] && continue   # 跳过注释
    [[ -z "${key// }" ]] && continue             # 跳过空行
    key="${key// }"
    export "$key=$rest"
done < "$BASE/vars.env"

for var in SUBSCRIBE_URL EXIT_SERVER EXIT_PORT EXIT_USER EXIT_PASS API_SECRET; do
    [ -n "${!var}" ] || { echo "ERROR: vars.env 缺少 $var"; exit 1; }
done

# ── 2. 从模板渲染 config.yaml，有变更则热重载 ──
NEW=$(envsubst '${SUBSCRIBE_URL}${EXIT_SERVER}${EXIT_PORT}${EXIT_USER}${EXIT_PASS}${API_SECRET}' < "$BASE/config.template.yaml")
OLD=$(cat "$BASE/config.yaml" 2>/dev/null || true)

if [ "$NEW" != "$OLD" ]; then
    echo "检测到配置变更，更新 config.yaml..."
    printf '%s\n' "$NEW" > "$BASE/config.yaml"
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$API/configs" \
        -H "Authorization: Bearer $API_SECRET" -H "Content-Type: application/json" \
        -d '{"path":"/root/.config/mihomo/config.yaml","force":false}')
    [ "$CODE" = "204" ] && echo "✓ 热重载成功" || { echo "✗ 热重载失败 (HTTP $CODE)"; exit 1; }
else
    echo "配置无变化，跳过重载"
fi

# ── 3. 刷新订阅节点 ──
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    "$API/providers/proxies/lelian_proxies" \
    -H "Authorization: Bearer $API_SECRET")
[ "$CODE" = "204" ] && echo "✓ 订阅节点已刷新" || echo "⚠ 订阅刷新返回 HTTP $CODE"

echo "========== 完成 =========="
