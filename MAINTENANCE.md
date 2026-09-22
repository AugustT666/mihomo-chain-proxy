# Mihomo 维护指南

## 部署位置

| 位置 | 目录 | 自动刷新 |
|------|------|---------|
| Ubuntu 工作站（当前主力） | `/home/august/mihomo-local` | ✅ 每小时 :17（用户 crontab） |
| NAS | `/vol1/mihomo` | ✅ 每小时 :00 |

两份内容一致，只差 `docker-compose.yml` 里 3 行挂载路径。

## 日常维护

### NAS（自动）
- **每小时** cron 运行 `update_subscription.sh`：
  1. 逐行解析 `vars.env`
  2. `envsubst` 渲染 `config.template.yaml`
  3. 与当前 `config.yaml` 做字符串 diff → 有变更才写盘 + 热重载
  4. `PUT /providers/proxies/lelian_proxies` 刷新订阅节点

  节点测速**不在这里做**——由内核按 config 里的 `health-check`（provider 60s / 组 180s）自行完成。

### 本机（自动，每小时 :17）
用户 crontab 里的一条（`crontab -l` 可看）。**不需要 root** —— 脚本只写 `august`
自己的文件并调 mihomo API，不碰 docker。

日志：`~/mihomo-update.log`（放 home 不放 /tmp，因为 /tmp 重启清空，
而"上一小时跑没跑成功"正是排障要查的）。

想立刻生效而不等整点：
```bash
cd /home/august/mihomo-local && bash update_subscription.sh
```

> 万一 cron 下的行为和手动跑不一致，**先怀疑 PATH**：交互 shell 里
> `envsubst` / `python3` 会解析到 `~/miniconda3/bin/`，而 cron 走 `/usr/bin/`。
> 已核验 `/usr/bin/envsubst` 存在、`/usr/bin/python3` 带 PyYAML 6.0.1，
> 所以 YAML 闸门在 cron 下有效。

## 更换机场订阅

```bash
nano vars.env            # 修改 SUBSCRIBE_URL（NAS 上是 /vol1/mihomo/vars.env）
bash update_subscription.sh
```

## 更换出口节点（SOCKS5）

```bash
nano vars.env            # 修改 EXIT_SERVER / EXIT_PORT / EXIT_USER / EXIT_PASS
bash update_subscription.sh
```

## 规则：机场规则 + 自有规则（2026-09-22 合并）

**机场订阅自带 515 条规则**（广告拦截、流媒体分流、国内直连…），但本项目的引用方式
（`proxy-provider`）会让 mihomo **只读节点列表、丢弃规则**。所以现在由
`sync_airport_rules.sh` 把它们捞回来，与自有规则合并。

合并后的规则分四层，**顺序就是优先级**：

| 层 | 内容 | 条数 |
|---|---|---:|
| 1 | 本地/垃圾流量（组播广播 REJECT、内网直连） | 8 |
| 2 | 自有规则（微信直连、AI 域名走代理链） | 10 |
| 3 | **机场规则**（自动生成，保持机场原顺序） | 515 |
| 4 | 国内直连 + `MATCH,Proxy` 兜底 | 3 |

合计 **536 条**。验证方法：

```bash
SEC=$(sed -n 's/^API_SECRET=//p' vars.env)
curl -s -H "Authorization: Bearer $SEC" http://127.0.0.1:9090/rules \
  | python3 -c "import sys,json;print(len(json.load(sys.stdin)['rules']),'条')"
```

### 自动同步

`update_subscription.sh` 每次运行都会调 `sync_airport_rules.sh` 重新生成
`airport_rules.inc`。所以机场更新规则后，**下一个周期自动跟上**，无需手工维护。

### 想改机场规则的落地策略

机场规则里的目标原本指向机场自己的策略组。改成本项目哪个组，由 `vars.env` 里的
`AIRPORT_GROUP_MAP` 决定（格式 `机场组=本项目组`，逗号分隔多项；当前映射到 `Proxy`，
即"机场认为该走代理的，都走本项目的代理链"）。

> 这张映射表刻意放在 `vars.env`（不入库）而不是代码里：既为脱敏（本仓库是公开的），
> 也让换机场时只改一行配置、不必动代码。

若你希望它们**直接用机场节点池**（绕过固定出口，延迟更低但出网 IP 会变），
把映射改成 `第一跳节点池` 即可。

> ⚠️ 改完必须跑 `bash update_subscription.sh` 并确认输出里有
> `✓ YAML 语法校验通过`——脚本有一道解析闸门，**配置解析不过就拒绝写盘**，
> 因为写盘发生在热重载之前，坏配置留盘会导致容器重启时起不来。

## 架构说明

```
[设备]
  ↓
mihomo :7897（规则分流）
  ↓ 命中 Proxy 规则
第一跳节点池（load-balance / round-robin，对 lelian_proxies 轮询，lazy: false）
  ↓
My-Exit-SOCKS（固定 SOCKS5 出口，地址见 vars.env:EXIT_SERVER）
  ↓
Internet
```

这是"**中转 + 落地**"结构：第一跳负责"怎么从国内出去"（线路质量），
`My-Exit-SOCKS` 负责"出去后以哪个 IP 出现"（身份）。

> `第一跳节点池` 是 `load-balance`（round-robin），**不是** `url-test`。
> 选轮询而非选最低延迟，是为了分散连接、避免所有流量挤在同一个节点上。
> 死节点由 provider 的 60s 健康检查自动剔除，`load-balance` 不会再分发到它们。

## 为什么不再自动挑选 DoH 解析器（2026-09-22 决策）

`boot.sh` 里曾有一个每 1800s 运行 `dns-select.sh` 的后台循环，已移除。三条理由：

**1. 它要修的故障当前不存在。** 它的设计目标是"某域名下的整批节点因解析到被墙 IP 而集体失效"。实测（2026-09-22）失败形态是**零散单点**：

| 域名 | 活 | 死 |
|---|---:|---:|
| 域名 A（承载 14 个节点） | 13 | 1 |
| 域名 B（承载 6 个节点）  | 5 | 1 |
| 域名 C（承载 5 个节点）  | 5 | 0 |
| 域名 D（承载 5 个节点）  | 5 | 0 |
| 域名 E（1 个节点）       | 0 | 1 |
| 域名 F（1 个节点）       | 0 | 1 |
| 一个 IP 型节点           | 0 | 1 |

真正"全灭"的几个域名**各只承载 1 个节点**（且其中一个是 IP 型节点，脚本本来就跳过它）。大域名只死 1–2 个，属于正常下线，健康检查已覆盖。

**2. 它在泄漏僵尸进程。** 每轮 67 个 `ssl_client`——busybox 的 `wget` 抓 `https://` 时会 fork 一个 `ssl_client` 做 TLS 握手，管道下游（`grep`/`cut`）提前退出使 `wget` 收 SIGPIPE 而死，来不及回收子进程；孤儿被过继给容器 PID 1，而 PID 1 是 mihomo（Go 程序，不回收别人的孩子），于是永久堆积。**每 30 分钟 67 个 ≈ 3200 个/天**，无界增长。

**3. 它直接改写"生成物"`config.yaml`**，与定时渲染流程存在同文件写竞争。

### 什么时候该用它

排查"**批量节点同时掉线**"时，手动跑一次看各解析器的加权可达率：

```bash
# 推荐：在宿主机上跑（真实 shell 会正常回收子进程，不产生僵尸）
cd /home/august/mihomo-local && CFG_DIR=$PWD ./dns-select.sh --dry-run

# 或在容器内（会留约 67 个僵尸，之后需重启容器清理）
docker exec mihomo /vol1/mihomo/dns-select.sh --dry-run
```

`--dry-run` 只报告不落盘。去掉它才会真的切换并同步 `vars.env` + `config.yaml`。

## 排查：僵尸进程

容器内看到一堆 `Z` 状态进程时，按这个查：

```bash
# 统计容器内僵尸数
CID=$(sudo docker inspect mihomo --format '{{.Id}}')
Z=0
for p in /proc/[0-9]*; do
  if grep -q "$CID" "$p/cgroup" 2>/dev/null && \
     grep -q '^State:.*Z' "$p/status" 2>/dev/null; then Z=$((Z+1)); fi
done
echo "僵尸数: $Z"

# 清理后重新计数，并列出仍存活的进程（移除自动挑选后应当只有 1 个：mihomo）
```

`ssl_client` 僵尸 = 有人在容器里用 busybox `wget` 抓 HTTPS。
**清理方法：`sudo docker compose restart mihomo`**（僵尸随进程表重建而清空）。

## 容器资源画像（2026-09-22 实测）

| 指标 | 值 |
|------|-----|
| 内存 | 89.5 MB（峰值 102 MB） |
| 主进程 mihomo RSS | 62.7 MB / 32 线程 |
| 活跃进程 | 1（只有 `mihomo`；移除自动挑选前是 3） |
| 内核 | v1.19.31（跟随镜像 `:latest`） |

---
其他问题交给 AI 处理，把这个目录告诉它即可。
