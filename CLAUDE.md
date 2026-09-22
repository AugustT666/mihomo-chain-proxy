# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 部署位置（同一套源，两处部署）

| 位置 | 目录 | 说明 |
|------|------|------|
| Ubuntu 工作站 | `/home/august/mihomo-local` | 当前主力（NAS 故障期间的替代） |
| NAS | `/vol1/mihomo` | 容器内路径也叫 `/vol1/mihomo`；NAS 上有每小时 cron |

两份内容一致，**唯一差别是 `docker-compose.yml` 里的宿主机挂载路径**（3 行）。
改动这份时请同步另一份，否则会静默分叉。

**两份都有每小时 cron**（2026-09-22 起本机也配上了）：
- NAS：`0 * * * * /vol1/mihomo/update_subscription.sh`
- 本机（用户 crontab，**不需要 root**——脚本只写 august 自己的文件 + 调 mihomo API，不碰 docker）：
  ```
  17 * * * * PATH=...; flock -n /tmp/mihomo_update.lock /home/august/mihomo-local/update_subscription.sh >> /home/august/mihomo-update.log 2>&1
  ```
  用 `flock` 防重叠；显式给 `PATH` 因为 cron 的 PATH 很窄。

改完 `vars.env` / `config.template.yaml` 可以手动跑一次立刻生效，也可以等下一个整点。

## Common Commands

```bash
# 渲染 config.template.yaml → config.yaml 并热重载（本机路径）
cd /home/august/mihomo-local && bash update_subscription.sh

# NAS 上查看 cron 日志：
tail -f /tmp/mihomo_update.log

# Docker 管理
cd /home/august/mihomo-local && sudo docker compose up -d   # 改了 compose 必须 recreate
sudo docker compose restart mihomo                          # 仅重启进程
sudo docker logs mihomo --tail=50

# Mihomo API — secret 在 vars.env:API_SECRET，端口 9090
SEC=$(sed -n 's/^API_SECRET=//p' vars.env)
curl -s -H "Authorization: Bearer $SEC" http://127.0.0.1:9090/proxies/第一跳节点池
curl -s -H "Authorization: Bearer $SEC" http://127.0.0.1:9090/providers/proxies/lelian_proxies

# DNS 解析器诊断（按需手动，非自动）
CFG_DIR=/home/august/mihomo-local ./dns-select.sh --dry-run
```

Web 面板：用任意 yacd / metacubexd 前端连 `http://<本机IP>:9090`，以 `vars.env` 的
`API_SECRET` 登录。**建议把前端放在本地跑**（它们都是纯静态页面）或使用镜像里自带的
dashboard——把 API 密钥填进第三方托管的页面，等于把密钥交给那个站点的运营者。

## Architecture

**Chain proxy flow:**
```
[Device] → mihomo :7897 → 第一跳节点池 → My-Exit-SOCKS → Internet
```

- **第一跳节点池** (`proxy-group`, **`load-balance`**): 对 `lelian_proxies` 做 `round-robin` 轮询，`lazy: false`，组健康检查 `interval: 180`。轮询而非 url-test 是为了分散连接、避免单点拥塞，死节点由健康检查自动剔除。
- **My-Exit-SOCKS** (`socks5`, 固定出口，凭据在 `vars.env:EXIT_*`): 出站落地节点。`dialer-proxy: 第一跳节点池` —— 它**物理上经由第一跳连接**，这就是"中转 + 落地"的链式结构。
- **lelian_proxies** (`proxy-provider`): 只是订阅数据源，**不能直接路由流量**；节点健康检查 `interval: 60`。

**Why both `lelian_proxies` and `第一跳节点池` exist:** Mihomo `proxy-provider` entries are data sources, not routable entities. A `proxy-group` wrapping them is required for `dialer-proxy` references and rule targets.

## Config System

`config.yaml` is **generated** — never edit it directly.

The source of truth is:
- `config.template.yaml` — YAML with `${VAR}` placeholders
- `vars.env` — values for those placeholders（订阅链接、出口凭据、API secret、PROXY_DNS）

`update_subscription.sh` 用 `envsubst` 渲染模板，与现有 `config.yaml` 做**字符串 diff**，有变化才写盘并热重载。
被替换的变量共 7 个：`${SUBSCRIBE_URL}` `${EXIT_SERVER}` `${EXIT_PORT}` `${EXIT_USER}` `${EXIT_PASS}` `${API_SECRET}` `${PROXY_DNS}`

> `dns-select.sh` 会直接改写 `config.yaml` 的 `proxy-server-nameserver` 段——这是对"生成物"的写入。
> 它只在**手动运行**时才会发生（自动循环已于 2026-09-22 移除，见 MAINTENANCE.md），
> 且脚本会先更新源头 `vars.env` 再同步产物，所以下次渲染不会冲突。

### 规则合并：机场规则 + 自有规则（2026-09-22 上线）

机场订阅本身是一份**完整 Clash 配置**（含 515 条 rules、它自己的 dns/proxy-groups）。
但本项目以 `proxy-provider` 引用它时，mihomo **只读 `proxies:` 段**——rules 全被丢弃。
`sync_airport_rules.sh` 把它们捞回来：

1. 从 `proxy_provider/lelian_proxies.yaml`（mihomo 已缓存的机场配置）抽取 `rules:` 段
2. **重写策略组名**：机场的主策略组 → 本项目的 `Proxy`（映射由 `vars.env:AIRPORT_GROUP_MAP` 提供，
   **刻意不写死在代码里**——本仓库公开，既为脱敏，也让换机场只需改一行配置）；并校验重写后每个目标都落在已知组内，否则报错退出
3. 丢弃终结 `MATCH`（由本项目自己的 `MATCH,Proxy` 兜底）
4. 写入 `airport_rules.inc`（**严格保持机场原始顺序**——顺序即语义）
5. `update_subscription.sh` 用 awk 把它注入 `config.template.yaml` 的 `# @@AIRPORT_RULES@@` 标记处

`rules` 段四层，**顺序即优先级**（mihomo 首个匹配生效）：

| 段 | 内容 | 为什么必须在这个位置 |
|---|---|---|
| 1 | 本地/垃圾流量：REJECT 组播广播、内网段直连 | 必须先于任何域名规则；机场对组播写的是 `DIRECT`，本项目要 `REJECT` |
| 2 | 自有规则：微信直连、AI 域名 → `Proxy` | **必须在机场规则之前**。机场把自己的 `GEOIP,CN,DIRECT` 放在它规则块的**末尾**当兜底——若自有规则排在其后，AI 域名一旦解析到 CN IP 就会被抢走直连而失效 |
| 3 | 机场规则 515 条（自动生成） | 保留机场原始顺序（它是"具体代理规则在前、`GEOIP,CN` 兜底直连在后"） |
| 4 | `cn` / `GEOIP,CN` 直连 + `MATCH,Proxy` | 段 4 的国内直连是**故意冗余**：万一 `airport_rules.inc` 缺失，也不会让全部流量被 `MATCH,Proxy` 吞进付费出口 |

**为什么不用 `rule-providers`**：官方文档里 classical 规则集是**两字段**格式
（`DOMAIN-SUFFIX,google.com`），目标由主配置的 `RULE-SET,name,target` 统一指定。
而机场规则是**三字段、目标混合**（`Proxy` 328 / `DIRECT` 160 / `REJECT` 27）。
走 `RULE-SET` 会把那 160 条 DIRECT 和 27 条 REJECT **错误地送进代理**。故必须逐条内联。

> `airport_rules.inc` 是**生成物，不入库**（同 `config.yaml`）。它由**你自己的**订阅生成，
> 内含你所用机场的规则集（其中可能有与其品牌相关的目标域名），不适合再分发。
> 新克隆的仓库首次渲染时它还不存在——那时渲染会提示，且 rules 段 4 的国内直连仍兜底；
> 跑一次 `update_subscription.sh`（需要有效的 `SUBSCRIBE_URL`）即可生成。

## Automation

**NAS 上** cron 每小时跑：
```
0 * * * * /vol1/mihomo/update_subscription.sh >> /tmp/mihomo_update.log 2>&1
```
实际行为：逐行解析 `vars.env` → `envsubst` 渲染 → 与 `config.yaml` 字符串 diff → 有变化才写盘 + `PUT /configs` 热重载 → `PUT /providers/proxies/lelian_proxies` 刷新订阅。
（**不做**健康检查、不等待、不汇报节点——节点测速由内核按 config 里的 `health-check` 自行完成。）

**本机（Ubuntu 工作站）** 同样由用户 crontab 每小时 :17 触发（见上方"部署位置"一节）。
日志：`~/mihomo-update.log`（放在 home 而不是 /tmp，因为 /tmp 重启即清空，
而"上一小时到底跑没跑成功"恰恰是出问题时要查的）。

## Key Config Values

| Item | Value |
|------|-------|
| Mihomo API port | `9090`（`external-controller: 0.0.0.0:9090`） |
| API secret | `vars.env:API_SECRET` |
| Mixed proxy port | `7897` |
| Subscription provider | `lelian_proxies` |
| First-hop group | `第一跳节点池`（`load-balance` / round-robin） |
| Fixed exit proxy | `My-Exit-SOCKS`（`dialer-proxy` → 第一跳节点池） |
| 内核版本 | 跟随镜像 `docker.1ms.run/metacubex/mihomo:latest`（实测 v1.19.31） |

## Routing Rules Summary

- `DOMAIN-SUFFIX,{openai,chatgpt,oaistatic,oaiusercontent,anthropic,claude,claudeusercontent}.*` → `Proxy`
- `DOMAIN-SUFFIX,cn` + `GEOIP,CN` + RFC1918 → `DIRECT`
- `169.254.0.0/16` / 组播 / 广播 → `REJECT`（云元数据探测等垃圾流量，绝不走付费代理）
- `MATCH` → `Proxy` (default)

`Proxy` group is `select` type with options: `My-Exit-SOCKS` (default), `第一跳节点池`, `DIRECT`.

## Changing Config

- **New subscription URL or exit node** → edit `vars.env`, then `bash update_subscription.sh`
- **New routing rules or DNS** → edit `config.template.yaml`, then `bash update_subscription.sh`
- **改 `docker-compose.yml`（含 `cap_add`/`devices`/挂载）** → 必须 `docker compose up -d` 重建容器，`restart` 不生效
- **机场规则指向的策略组要改名 / 换机场** → 改 `vars.env` 的 `AIRPORT_GROUP_MAP`（格式 `机场组=本项目组`，逗号分隔多项），然后跑 `sync_airport_rules.sh --check` 看分布是否合理
- **`update_subscription.sh` 的执行顺序有意义**：先刷新 provider（否则抽到的是上一周期的规则）→ 再同步规则 → 再渲染 → **YAML 解析闸门** → 才写盘 + 热重载。
  写盘在重载之前，所以解析闸门是必须的——否则一份 mihomo 读不懂的配置会留在磁盘上，下次重启直接 crash loop。

## 已移除 / 已纠正的历史内容

- ❌ `archive/` 目录（`apply.sh`、`test-chain.sh`）——**不存在**，曾在此文档中被引用，已删除该行。
- ❌ `boot.sh` 里的"每 1800s 自动挑选 DoH 解析器"循环——2026-09-22 移除（僵尸泄漏 + 要修的故障不存在）。`dns-select.sh` 保留为手动工具。
- ❌ `第一跳节点池` 曾被本文档描述为 `url-test`——实际是 `load-balance`，已纠正。
