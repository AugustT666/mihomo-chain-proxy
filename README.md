# Mihomo 链式代理配置

一套基于 [mihomo (Clash.Meta)](https://github.com/MetaCubeX/mihomo) 的**链式代理**配置，
容器化部署、无人值守。

```
[设备] → mihomo :7897 → 第一跳节点池(廉价机场订阅) → 固定出口(SOCKS5) → Internet
```

即代理圈说的「**中转 + 落地**」：第一跳负责"怎么从墙内出去"（线路质量），
固定出口负责"出去后以哪个 IP 出现"（身份稳定）。

> 引擎用官方镜像 `metacubex/mihomo`，本项目**只提供配置和脚本**，不含任何自建内核。
> 密钥（订阅链接、出口凭据、API 密钥）全部通过 `vars.env` 注入，**不入库**。

## 它解决/覆盖的事

| 能力 | 说明 |
|---|---|
| **链式代理** | 靠原生 `dialer-proxy` + `load-balance` + `proxy-provider`，零自研代码 |
| **机场规则合并** | 机场订阅自带完整规则集，但以 `proxy-provider` 引用时 mihomo **只读节点列表、丢弃规则**。本项目把规则捞回来与自有规则按优先级合并（详见下） |
| **TUN 全局代理** | 让**不认 `http_proxy` 环境变量**的程序也走代理（含 Docker 容器内流量、非 HTTP 协议）。自带防自锁配置 |
| **定时热重载** | cron 每小时：刷新订阅 → 重新抽取规则 → 渲染 → 热重载。机场更新规则后自动跟上 |
| **渲染安全闸门** | 关键字段非空校验 + YAML 解析闸门 + 热重载失败自动回滚 |

## 快速开始

```bash
git clone <this-repo> && cd <repo>

# 1. 填密钥（vars.env 已在 .gitignore 中，不会被提交）
cp vars.env.example vars.env
chmod 600 vars.env
nano vars.env      # 填 SUBSCRIBE_URL / EXIT_* / API_SECRET / PROXY_DNS / AIRPORT_GROUP_MAP

# 2. 渲染配置并启动
bash update_subscription.sh      # 渲染 config.yaml（若容器已在运行则热重载）
docker compose up -d

# 3. 验证（应返回 204）
curl -x http://127.0.0.1:7897 -s -o /dev/null -w "%{http_code}\n" \
     http://www.gstatic.com/generate_204
```

`vars.env` 的 7 个键缺一不可，脚本会强制校验：
`SUBSCRIBE_URL` `EXIT_SERVER` `EXIT_PORT` `EXIT_USER` `EXIT_PASS` `API_SECRET` `PROXY_DNS`
外加 `AIRPORT_GROUP_MAP`（见下）。

> **绝不要用裸 `envsubst` 渲染模板。** `envsubst` 从环境变量取值，而 `vars.env` 的值
> 并未 export 到环境——直接渲染会把所有占位符静默替换成空字符串，
> 出口节点/订阅链接/密钥全部被抹掉，代理链当场断裂且**不报任何错**。
> 一律走 `update_subscription.sh`（它会先 export 再渲染，并做校验）。

## 文件

| 文件 | 作用 |
|---|---|
| `config.template.yaml` | 配置骨架（代理组、DNS、TUN、规则四段），带占位符 |
| `vars.env` | 占位符的真实取值 —— **自己创建，勿分享**（已在 .gitignore） |
| `update_subscription.sh` | 渲染 → 校验 → 写盘 → 热重载。**其余脚本的入口** |
| `sync_airport_rules.sh` | 从订阅里抽取规则、重写策略组名、生成 `airport_rules.inc` |
| `boot.sh` | 容器入口。目前只做 `exec /mihomo`（见文件内注释说明历史） |
| `dns-select.sh` | **按需手动**的 DoH 解析器诊断工具（不再是常驻循环） |
| `airport_rules.inc` | 生成物，不入库 |
| `docker-compose.yml` | 容器定义（`network_mode: host` + TUN 所需的 cap/device） |
| `CLAUDE.md` / `MAINTENANCE.md` | 给 AI / 给人的维护文档 |

## 规则四段（顺序即优先级）

mihomo 是**首个匹配生效**，所以顺序就是语义：

| 段 | 内容 | 为什么在这个位置 |
|---|---|---|
| 1 | 本地/垃圾流量：REJECT 组播广播、内网段直连 | 必须先于任何域名规则；机场对组播写的是 `DIRECT`，本项目要 `REJECT` |
| 2 | 自有规则：微信直连、AI 域名走代理链 | **必须在机场规则之前**——机场把自己的 `GEOIP,CN,DIRECT` 放在它规则块**末尾**当兜底，若自有规则排其后，AI 域名一旦解析到 CN IP 就会被抢走直连 |
| 3 | 机场规则（自动生成，保持机场原始顺序） | 顺序有意义：机场是"具体代理规则在前、`GEOIP,CN` 兜底直连在后" |
| 4 | `cn` / `GEOIP,CN` 直连 + `MATCH,Proxy` | 第 4 段的国内直连是**故意冗余**：万一 `airport_rules.inc` 缺失，也不会让全部流量被 `MATCH,Proxy` 吞进付费出口 |

**为什么不用 `rule-providers`**：官方文档里 classical 规则集是**两字段**格式
（`DOMAIN-SUFFIX,google.com`），目标由主配置的 `RULE-SET,name,target` 统一指定。
而机场规则是**三字段、目标混合**。走 `RULE-SET` 会把其中所有非代理目标的规则
（实测 160 条 DIRECT + 27 条 REJECT）**错误地送进代理**。故必须逐条内联。

### 策略组名映射（`AIRPORT_GROUP_MAP`）

机场规则里的目标指向**机场自己的**策略组，必须重写成本项目存在的组，否则 mihomo 会
因目标不存在而拒绝整份配置。映射表放在 `vars.env`：

```
AIRPORT_GROUP_MAP=机场主组名=Proxy
```

- 映射到 `Proxy` → 走本项目代理链（第一跳节点池 → 固定出口），保住固定出网身份
- 映射到 `第一跳节点池` → 直接用机场节点，延迟更低但出网 IP 会随节点变化

> 映射表刻意放在 `vars.env`（不入库）而非代码里 —— 既为脱敏，也让**换机场时只改一行配置**。

## TUN 全局代理

只靠 `http_proxy` 环境变量不算全局：**不认这个变量的程序、Docker 容器内的流量、
非 HTTP 协议**都会漏出去直连。TUN 才能接管全部流量。

容器需要：

```yaml
cap_add: [NET_ADMIN]
devices: ["/dev/net/tun:/dev/net/tun"]
```

⚠️ **如果你是通过 SSH 远程管理这台机器的，`route-exclude-address` 是安全底线**：
必须把管理网段排除在 TUN 之外，否则隧道一抖动你就再也连不上、只能物理接触机器。
模板里已按常见私有网段给全（`10/8`、`172.16/12`、`192.168/16`、`100.64/10` 等）。

两个必须记住的点：

- **`strict-route` 必须为 `false`**。官方文档：Linux 上它会让"不支持的网络不可达"
  并强制所有连接走 TUN —— 在远程机器上等于**自锁开关**。
- 验证是否生效，用"**酸测试**"：一个不带任何代理环境变量的程序，应当也能拿到出口 IP。
  ```bash
  env -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy \
      curl -s https://api.ipify.org     # 应返回你的出口 IP
  ```

## 渲染流水线的两条硬约束

写这个项目时踩过，记下来免得重踩：

1. **必须原地写入**（`cat tmp > config.yaml`），**绝不能用 `mv`**。
   `config.yaml` 是以**单文件 bind mount** 方式挂进容器的；`mv` 会换掉 inode，
   而 bind mount 绑的是原 inode —— **容器侧将永远看不到更新，且不报任何错**。
2. **写盘发生在热重载之前**，所以必须有闸门：否则一份 mihomo 读不懂的配置会留在磁盘上，
   容器下次重启直接 crash loop。本项目有三道：关键字段非空 → YAML 解析 → 重载失败自动回滚。

## 定时任务

```
17 * * * * PATH=...; flock -n /tmp/mihomo_update.lock \
           /path/to/update_subscription.sh >> ~/mihomo-update.log 2>&1
```

不需要 root：脚本只写自己的文件 + 调 mihomo HTTP API，不碰 docker。
`flock` 防重叠；显式给 `PATH`，因为 cron 的 PATH 很窄
（**注意**：交互 shell 里 `envsubst`/`python3` 常被 conda 等覆盖，
cron 下会走 `/usr/bin/` —— 两处行为不一致时先怀疑这个）。

## 安全说明

- `vars.env`、`config.yaml`、`proxy_provider/lelian_proxies.yaml`、`airport_rules.inc`
  均已列入 `.gitignore`。**首次提交前请自行确认**：`git status` 里不应出现它们。
- 本项目默认不开 mixed-port 认证（`authentication`）。**若部署在不受信任的网络里，
  请自行开启**，否则同网段任何人都能把它当免费代理用，消耗你的付费流量、
  并以你的出口身份发出流量。
- `external-controller` 默认绑 `0.0.0.0:9090`。API 密钥请用随机长串
  （`openssl rand -hex 24`），并且**不要把密钥填进第三方托管的前端页面**。

## 许可与免责

本项目只提供配置与脚本，不含任何代理服务或节点。使用前请确认符合你所在地区的法律法规。
