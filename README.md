# Mihomo 链式代理配置

一套基于 [mihomo (Clash.Meta)](https://github.com/MetaCubeX/mihomo) 的**链式代理**配置：

```
[设备] → mihomo :7897 → 第一跳节点池(机场订阅) → 固定出口(SOCKS5) → Internet
```

- **第一跳节点池**：从机场订阅拉取节点，用 `load-balance` 把连接**分散到多个存活节点**，自动跳过失效节点、不因延迟波动频繁切换。
- **固定出口**：所有流量最终从一个你指定的 SOCKS5 出口发出（出口 IP 稳定）。
- 国内域名 / GEOIP CN / 内网地址直连；本地伪地址与云元数据探测（169.254 等）直接丢弃，不浪费付费出口。

> 引擎用官方镜像 `metacubex/mihomo`，本项目只提供**配置**。密钥（订阅链接、出口凭据、API 密钥）通过 `vars.env` 注入，**不包含在本导出中**——请自行填写。

## 快速开始

```bash
# 1. 填写你自己的密钥
cp vars.env.example vars.env
nano vars.env        # 填入 SUBSCRIBE_URL / EXIT_* / API_SECRET

# 2. 生成 config.yaml 并启动
bash update_subscription.sh          # 渲染 config.yaml（若容器已运行则热重载）
docker compose up -d                 # 首次启动

# 3. 验证
curl -x socks5h://127.0.0.1:7897 -s https://www.gstatic.com/generate_204 -o /dev/null -w "%{http_code}\n"
```

## 配置体系

`config.yaml` 是**生成文件，不要直接编辑**。真源是：

| 文件 | 作用 |
|------|------|
| `config.template.yaml` | 带 `${VAR}` 占位符的配置骨架（路由规则、代理组、DNS） |
| `vars.env` | 占位符的真实取值（订阅链接、出口凭据、API 密钥）——**自己创建，勿分享** |
| `update_subscription.sh` | 用 `envsubst` 渲染模板 → 有变更时热重载 → 刷新订阅节点 |

改动方式：
- **换订阅 / 换出口** → 编辑 `vars.env` → `bash update_subscription.sh`
- **改路由规则 / DNS / 代理组** → 编辑 `config.template.yaml` → `bash update_subscription.sh`

可选：挂 cron 每小时自动刷新订阅并应用 `vars.env` 变更：
```
0 * * * * /path/to/update_subscription.sh >> /tmp/mihomo_update.log 2>&1
```
（节点测速由 mihomo 按 `health-check.interval` 自动完成，脚本不再手动触发。）

## 关键端口

| 项 | 值 |
|----|----|
| 混合代理端口 (HTTP/SOCKS) | `7897` |
| API (external-controller) | `9090` |

> 安全提示：`external-controller` 默认监听 `0.0.0.0:9090`。若非可信局域网，请改为 `127.0.0.1:9090` 或设置强 `API_SECRET`。
