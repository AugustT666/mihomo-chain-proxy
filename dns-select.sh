#!/bin/sh
# dns-select.sh — 自动挑选“当前最能连上”的 DoH 解析器
#
# 背景：机场节点域名（如 node.example-airport.com）由 GTM 轮询一组 IP，
#       不同解析器问到的 IP 不同，其中一部分被墙。
#       本脚本对候选解析器逐一采样、把解析出的 IP 拿去实测，
#       选可达率最高的那个写进 vars.env，并同步 config.yaml。
#
# 两个关键设计：
#   * 按域名承载的节点数加权 —— 一个域名下有 26 个节点，
#     它可达与否，权重就该是只有 1 个节点的域名的 26 倍。
#   * 迟滞 —— 只有“最优”明显优于“当前”才切换，避免来回抖动。
#
# 用法:  dns-select.sh [--dry-run]
# 退出码: 0 = 已切换（dry-run 时为“会切换”）
#         1 = 保持当前（已是最优 / 优势不足）
#         2 = 没有可用解析器（机场侧问题，保持现状）
#
# 只依赖 busybox：sh/sed/grep/awk/wget/nc

set -u

CFG_DIR="${CFG_DIR:-/vol1/mihomo}"
PROVIDER="$CFG_DIR/proxy_provider/lelian_proxies.yaml"
VARS="$CFG_DIR/vars.env"
CONFIG="$CFG_DIR/config.yaml"

SAMPLES="${SAMPLES:-3}"            # 每个解析器对每个域名采样几次
PROBE_TIMEOUT="${PROBE_TIMEOUT:-5}"
MARGIN="${MARGIN:-0.15}"           # 迟滞：最优需比当前高出这么多才切换

RESOLVERS="https://doh.pub/dns-query
https://1.12.12.12/dns-query
https://dns.alidns.com/resolve
https://doh.360.cn/dns-query
https://doh.qq.com/dns-query"

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
log() { echo "[dns-select] $*"; }

WORK=$(mktemp) || exit 2
trap 'rm -f "$WORK"' EXIT INT TERM

# ── 1. 从订阅里取 (域名, 代表端口, 该域名下节点数) ──
#     跳过 IP 型 server；代表端口取该域名下出现次数最多的那个
PAIRS=$(sed -n 's/.*server: *\([^,}]*\), *port: *\([0-9]*\).*/\1 \2/p' "$PROVIDER" \
        | grep -vE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ' \
        | awk '{ c[$1" "$2]++; n[$1]++ }
               END { for (k in c) { split(k, a, " ")
                                    if (c[k] > best[a[1]]) { best[a[1]] = c[k]; port[a[1]] = a[2] } }
                     for (x in n) print x, port[x], n[x] }')
if [ -z "$PAIRS" ]; then
    log "ERROR: 无法从订阅中提取节点域名 ($PROVIDER)"
    exit 2
fi

CURRENT=$(sed -n 's/^PROXY_DNS=//p' "$VARS" 2>/dev/null | head -1)

# ── 2. 工具函数 ──
doh_ips() {   # $1=resolver  $2=域名  -> 打印 A 记录，每行一个
    wget -q -O- -T 6 --header="accept: application/dns-json" \
         "$1?name=$2&type=A" 2>/dev/null \
      | tr '}' '\n' | grep '"type":1' \
      | grep -oE '"data":"[0-9.]+"' | cut -d'"' -f4
}
tcp_ok() {    # $1=ip  $2=port
    nc -z -w "$PROBE_TIMEOUT" "$1" "$2" >/dev/null 2>&1
}

# ── 3. 逐解析器、逐域名采样 + 实测 ──
#     WORK 行格式: <resolver> <域名> <可达> <采样> <权重>
PRE_DOM=$(printf '%s\n' "$PAIRS" | head -1 | cut -d' ' -f1)

for RES in $RESOLVERS; do
    # 预检：一次查询都不应答复，整家跳过。
    # 否则每家要在每个域名上白等 SAMPLES 次超时（约 50s+）。
    if [ -z "$(doh_ips "$RES" "$PRE_DOM")" ]; then
        printf '%s %s %s %s %s\n' "$RES" "$PRE_DOM" 0 0 0 >> "$WORK"
        continue
    fi
    # 必须用 while-read 逐行取：for x in $PAIRS 会按空格拆词
    while read -r DOM PORT NODES; do
        [ -z "${DOM:-}" ] && continue
        [ -z "${PORT:-}" ] && continue
        ok=0; tot=0
        n=0
        while [ "$n" -lt "$SAMPLES" ]; do
            n=$((n + 1))
            for IP in $(doh_ips "$RES" "$DOM"); do
                tot=$((tot + 1))
                if tcp_ok "$IP" "$PORT"; then ok=$((ok + 1)); fi
            done
        done
        printf '%s %s %s %s %s\n' "$RES" "$DOM" "$ok" "$tot" "${NODES:-1}" >> "$WORK"
    done <<EOF
$PAIRS
EOF
done

log "采样明细（域名后的数字 = 该域名承载的节点数）:"
awk '{ printf "[dns-select]   %-32s %-18s %s/%s  (x%s)\n", $1, $2, $3, $4, $5 }' "$WORK"
log "加权总分:"
awk '{ n[$1] += $3 * $5; d[$1] += $4 * $5 }
     END { for (r in n) printf "[dns-select]   %-32s %s\n", r, (d[r] > 0 ? n[r] "/" d[r] : "无应答") }' "$WORK"
log "当前生效: ${CURRENT:-(未设置)}"

# ── 4. 决策（按节点数加权 + 迟滞）──
DECISION=$(awk -v cur="$CURRENT" -v margin="$MARGIN" '
    { num[$1] += $3 * $5; den[$1] += $4 * $5 }
    END {
        for (r in num) {
            if (den[r] <= 0) continue
            score = num[r] / den[r]
            if (!set || score > best_r) { set = 1; best = r; best_r = score; best_num = num[r]; best_den = den[r] }
            if (r == cur) { cur_r = score; cur_ok = num[r]; cur_den = den[r]; cur_set = 1 }
        }
        if (!set)          { print "NONE"; exit }
        # 最优也一个都连不上 —— 绝不能切过去
        if (best_num <= 0) { print "NONE"; exit }
        if (cur_set && cur_ok > 0 && (best_r - cur_r) <= margin) {
            print "KEEP " best " " best_num "/" best_den; exit
        }
        print "SWITCH " best " " best_num "/" best_den
    }' "$WORK")

set -- $DECISION
ACTION=${1:-NONE}
BEST_RES=${2:-}

case "$ACTION" in
    NONE)
        log "没有可用解析器（全都连不上）—— 保持现状"
        exit 2 ;;
    KEEP)
        log "最优 $BEST_RES ($3)，但相对当前 $CURRENT 优势不足或已是最优 —— 保持不变"
        exit 1 ;;
    SWITCH)
        log "切换目标: $BEST_RES  (加权 $3)" ;;
    *)
        log "内部错误：决策=$DECISION"; exit 2 ;;
esac

if [ "$DRY" = 1 ]; then
    log "[dry-run] 将会切换: ${CURRENT:-(未设置)}  ->  $BEST_RES"
    exit 0
fi

# ── 5. 落盘:更新 vars.env（源头）+ 同步 config.yaml（产物） ──
if grep -q '^PROXY_DNS=' "$VARS" 2>/dev/null; then
    sed -i "s|^PROXY_DNS=.*|PROXY_DNS=$BEST_RES|" "$VARS"
else
    printf 'PROXY_DNS=%s\n' "$BEST_RES" >> "$VARS"
fi
log "已更新 vars.env"

# 替换 config.yaml 里 proxy-server-nameserver 下的条目；
# 用“写临时文件再 cat 回去”保留原权限（600，含密钥）
if [ -f "$CONFIG" ]; then
    TMP="$CONFIG.tmp.$$"
    awk -v url="$BEST_RES" '
        /^  proxy-server-nameserver:/ {
            print
            replaced = 0
            while ((getline nxt) > 0) {
                if (nxt ~ /^  - /) { if (!replaced) { print "  - " url; replaced = 1 }; continue }
                print nxt; break
            }
            if (!replaced) print "  - " url
            next
        }
        { print }
    ' "$CONFIG" > "$TMP" && cat "$TMP" > "$CONFIG" && rm -f "$TMP"
    log "已同步 config.yaml"
fi

log "完成: ${CURRENT:-(未设置)} -> $BEST_RES"
exit 0
