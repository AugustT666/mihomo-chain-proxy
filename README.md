# mihomo-chain-proxy

基于 [mihomo (Clash.Meta)](https://github.com/MetaCubeX/mihomo) 的链式代理配置。
容器化部署，用机场节点做中转、用固定 SOCKS5 出口做落地，配置自动更新。

## 特性

- **链式代理** — 出口经第一跳节点连接（原生 `dialer-proxy`），出网 IP 稳定
- **规则合并** — 合并机场订阅自带的规则集与自有规则
- **TUN 全局代理** — 不依赖 `http_proxy`，不认代理变量的程序也能被接管
- **自动热重载** — cron 定时刷新订阅、重组规则、重载配置
- **渲染校验** — 关键字段非空 + YAML 解析 + 热重载失败自动回滚

## 架构

```
[设备] → mihomo :7897 → 第一跳节点池(机场订阅) → 固定出口(SOCKS5) → Internet
```

| 组件 | 说明 |
|---|---|
| 第一跳节点池 | `load-balance` 轮询机场节点，失效节点由健康检查自动剔除 |
| 固定出口 | `My-Exit-SOCKS` 经 `dialer-proxy` 从第一跳出去，出网 IP 固定 |
| 分流 | 国内域名 / GEOIP CN / 内网地址直连；本地伪地址与云元数据探测直接丢弃 |

## 快速开始

### 1. 准备变量

```bash
git clone https://github.com/AugustT666/mihomo-chain-proxy.git
cd mihomo-chain-proxy
cp vars.env.example vars.env && chmod 600 vars.env
```

编辑 `vars.env`：

| 变量 | 说明 |
|---|---|
| `SUBSCRIBE_URL` | 机场订阅链接 |
| `EXIT_SERVER` `EXIT_PORT` `EXIT_USER` `EXIT_PASS` | 出口 SOCKS5 凭据 |
| `API_SECRET` | mihomo API 密钥（也是面板密码），建议 `openssl rand -hex 24` |
| `PROXY_DNS` | 解析代理服务器域名用的 DoH 地址 |
| `AIRPORT_GROUP_MAP` | 机场策略组 → 本项目策略组的映射，格式 `机场组=Proxy` |

### 2. 启动

```bash
bash update_subscription.sh     # 渲染 config.yaml
docker compose up -d
```

### 3. 验证

```bash
curl -x http://127.0.0.1:7897 -s -o /dev/null -w "%{http_code}\n" \
     http://www.gstatic.com/generate_204        # 期望 204
```

## 配置

`config.yaml` 是**生成文件**，不要直接编辑。改这两个源文件：

| 文件 | 改什么 |
|---|---|
| `config.template.yaml` | 路由规则、代理组、DNS、TUN 开关 |
| `vars.env` | 订阅链接、出口凭据、API 密钥 |

改完运行 `bash update_subscription.sh` 生效 —— 它通过 API 热重载，不需要重启容器。
只有改 `docker-compose.yml` 才需要 `docker compose up -d` 重建。

### 规则顺序

`rules` 分四段。mihomo 是**首个匹配生效**，所以顺序就是优先级：

| 段 | 内容 |
|---|---|
| 1 | 本地与垃圾流量：组播/广播 REJECT，内网段直连 |
| 2 | 自有规则：微信直连，AI 域名走代理 |
| 3 | 机场规则（自动生成，保持机场原始顺序） |
| 4 | 国内直连 + `MATCH,Proxy` 兜底 |

第 2 段必须排在第 3 段之前：机场把自己的 `GEOIP,CN,DIRECT` 放在规则块末尾当兜底，
自有规则若在其后，AI 域名解析到 CN IP 时会被抢走直连。

### TUN

默认开启。**如果这台机器是你远程 SSH 管理的**，`route-exclude-address` 必须包含你的
管理网段（模板已按常见私有网段给全），否则隧道抖动会导致失联；`strict-route` 保持
`false`，它在 Linux 上相当于自锁开关。

不需要全局代理的话，从 `docker-compose.yml` 删掉 `network_mode`、`cap_add`、`devices` 三处即可。

## 常用操作

```bash
bash update_subscription.sh        # 改完配置后生效
tail -f ~/mihomo-update.log        # 自动更新日志

docker compose up -d               # 重建容器（改 compose 后）
docker compose restart mihomo      # 仅重启
docker logs mihomo --tail=50

# 查询 API
SEC=$(sed -n 's/^API_SECRET=//p' vars.env)
curl -s -H "Authorization: Bearer $SEC" http://127.0.0.1:9090/proxies
```

## 文件

| 文件 | 作用 |
|---|---|
| `config.template.yaml` | 配置模板（含占位符） |
| `vars.env` | 变量取值，不入库 |
| `update_subscription.sh` | 渲染 → 校验 → 热重载 |
| `sync_airport_rules.sh` | 抽取机场规则、重写策略组名 |
| `boot.sh` | 容器入口 |
| `dns-select.sh` | DoH 解析器诊断工具（手动运行） |
| `CLAUDE.md` `MAINTENANCE.md` | 维护与排障文档 |

## 常见问题

**为什么要用 `update_subscription.sh` 而不是直接 `envsubst`？**
`envsubst` 从环境变量取值，而 `vars.env` 的值并未 export 到环境。直接渲染会把所有
占位符替换成空字符串，代理链断开且不报错。

**机场规则为什么不用 `rule-providers` 引用？**
classical 规则集是两字段格式，目标由 `RULE-SET` 统一指定；而机场规则是三字段、
目标混合（代理 / DIRECT / REJECT 都有）。用 `RULE-SET` 会把 DIRECT 和 REJECT
的规则错误地送进代理，因此需要逐条内联。

**改了 `vars.env` 要重启容器吗？**
不用。`update_subscription.sh` 会通过 API 热重载。只有改 `docker-compose.yml` 才要重建。

**换了机场怎么办？**
改 `vars.env` 的 `SUBSCRIBE_URL` 和 `AIRPORT_GROUP_MAP`，重新运行 `update_subscription.sh`。

## 安全提示

- 本配置需要 `NET_ADMIN` 和 `/dev/net/tun`，容器因此拥有**宿主机的网络控制权**
  （可改路由表、创建网卡）。这是宿主机级 TUN 的必然代价，请只使用可信镜像。
- 镜像默认来自第三方源（`docker.1ms.run`）且未固定版本。介意的话改用官方
  `metacubex/mihomo`，或按 digest 固定（写法见 `docker-compose.yml` 注释）。
- mixed-port 默认**无认证**。部署在不受信任的网络里请自行添加 `authentication`，
  否则同网段任何人都能把它当作免费代理使用。
- `vars.env`、`config.yaml`、`airport_rules.inc` 等已在 `.gitignore` 中，
  提交前请确认 `git status` 不包含它们。

## 许可

本项目只提供配置与脚本，不含任何代理服务或节点。
