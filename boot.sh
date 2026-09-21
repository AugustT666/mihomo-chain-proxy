#!/bin/sh
# boot.sh — mihomo 容器的入口包装（全自动，无需人工干预）
#
#   1) 立即启动 mihomo —— 不因挑选解析器而拖慢容器启动
#   2) 后台立刻做一次挑选，之后每 RESELECT_INTERVAL 秒复查
#      只有真的切换了才热重载；当前解析器健康时什么都不做
#
# 只依赖 busybox：sh/sed/awk/wget/nc

set -u

CFG_DIR=/vol1/mihomo
VARS="$CFG_DIR/vars.env"
SELECTOR="$CFG_DIR/dns-select.sh"
API_HOST=127.0.0.1
API_PORT=9090
API_PATH=/configs

log() { echo "[boot] $*"; }

api_token() {
    sed -n 's/^API_SECRET=//p' "$VARS" 2>/dev/null | head -1
}

# 等 mihomo 的 API 起来（最多约 60s）
wait_api() {
    i=0
    while [ "$i" -lt 60 ]; do
        if nc -z -w 2 "$API_HOST" "$API_PORT" >/dev/null 2>&1; then return 0; fi
        i=$((i + 1))
        sleep 1
    done
    return 1
}

# 用裸 HTTP PUT 触发 mihomo 热重载
# （busybox 的 wget 只支持 GET/POST，不支持 PUT，所以走 nc）
reload() {
    tok=$(api_token)
    if [ -z "$tok" ]; then
        log "拿不到 API_SECRET，跳过热重载"
        return 1
    fi
    if ! wait_api; then
        log "mihomo API 未就绪，跳过热重载"
        return 1
    fi
    body='{"path":"/root/.config/mihomo/config.yaml","force":false}'
    len=$(printf '%s' "$body" | wc -c)
    resp=$(
        {
            printf 'PUT %s HTTP/1.1\r\n' "$API_PATH"
            printf 'Host: %s:%s\r\n' "$API_HOST" "$API_PORT"
            printf 'Authorization: Bearer %s\r\n' "$tok"
            printf 'Content-Type: application/json\r\n'
            printf 'Content-Length: %s\r\n' "$len"
            printf 'Connection: close\r\n\r\n'
            printf '%s' "$body"
        } | nc -w 5 "$API_HOST" "$API_PORT" 2>/dev/null | head -1
    )
    case "$resp" in
        *204*) log "热重载成功"; return 0 ;;
        *)     log "热重载返回: ${resp:-（无响应）}"; return 1 ;;
    esac
}

# 跑一次挑选；切换过（退出码 0）才热重载
run_select() {
    [ -x "$SELECTOR" ] || { log "找不到 $SELECTOR，跳过自动挑选"; return 0; }
    if "$SELECTOR"; then
        log "解析器已切换，热重载 mihomo"
        reload
    fi
}

# ── 后台：立即挑一次，之后定期复查 ──
INTERVAL=${RESELECT_INTERVAL:-1800}
(
    log "后台自动挑选已启动（首次立即执行，之后每 ${INTERVAL}s）"
    run_select
    while true; do
        sleep "$INTERVAL"
        run_select
    done
) &

# ── 立即启动 mihomo ──
log "启动 mihomo"
exec /mihomo
