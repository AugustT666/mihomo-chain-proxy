#!/bin/sh
# boot.sh — mihomo 容器的入口包装
#
# 这个文件曾经包含一个"后台定期自动挑选 DoH 解析器"的循环（每 1800s 调用
# dns-select.sh，切换后热重载）/ 已于 2026-09-22 移除，原因见 MAINTENANCE.md：
#
#   1) 它要修的故障当前不存在。它的设计目标是"某域名下整批节点因解析到被墙 IP
#      而集体失效"，但实测失效形态是【零散单点】：承载 14 / 6 个节点的大域名
#      各有 13 / 5 个活，真正"全灭"的几个域名各只承载 1 个节点，其中还有一个是
#      IP 型节点（脚本本来就跳过 IP 型 server）。
#      零散单点由 proxy-provider 的 60s 健康检查自动剔除，无需解析器选择。
#
#   2) 它在泄漏僵尸进程。每轮泄漏 67 个 ssl_client（busybox wget 做 HTTPS 时的
#      TLS 助手进程，管道下游提前退出导致它成为孤儿，而容器 PID 1 是 mihomo，
#      Go 程序不会回收别人的孩子）。每 30 分钟一轮 ≈ 3200 个/天，无界增长。
#      实测：开机 47 分钟已堆积 134 个，两簇各 67 个，正好对应两次运行。
#
#   3) 它直接改写"生成物" config.yaml，与定时渲染 config.template.yaml 的流程
#      存在同文件写竞争。
#
# dns-select.sh 保留为**按需手动**的诊断工具（排查"批量节点掉线"时用）：
#
#   推荐在宿主机上跑（真实 shell 会正常回收子进程，不产生僵尸）：
#     cd /home/august/mihomo-local && CFG_DIR=$PWD ./dns-select.sh --dry-run
#
#   或在容器内跑（会留约 67 个僵尸，需重启容器清理）：
#     docker exec mihomo /vol1/mihomo/dns-select.sh --dry-run
#
# 只依赖 busybox：sh

set -u

log() { echo "[boot] $*"; }

log "启动 mihomo（自动 DNS 挑选已停用；如需诊断请手动运行 dns-select.sh）"
exec /mihomo
