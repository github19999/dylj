# sing-box 订阅链接生成器

自动读取 `/etc/sing-box/config.json`，解析所有 inbound 配置，生成可直接导入客户端的订阅链接（明文 + Base64 双格式输出）。

---

## 功能特性

- 自动获取服务器公网 IP，无需手动填写地址
- 支持带 `//` 行注释的非标准 JSON 配置（自动清洗）
- 监听地址为 `::` / `0.0.0.0` 时自动替换为公网 IP
- 同时输出明文订阅文件和 Base64 编码订阅文件
- 可选注册 systemd 定时任务，每日自动刷新

### 支持的协议

| 协议 | 订阅格式 | 备注 |
|------|----------|------|
| VLESS | `vless://` | 支持 TCP / WS / gRPC / XTLS-Vision / REALITY |
| VMess | `vmess://` | Base64 JSON 格式（V2 标准） |
| Trojan | `trojan://` | 支持 TCP / WS |
| Shadowsocks | `ss://` | 支持所有加密方法，含 2022 系列 |
| Hysteria2 | `hysteria2://` | 含上下行限速参数 |
| TUIC | `tuic://` | 含拥塞控制、ALPN 参数 |
| AnyTLS | `anytls://` | TLS 封装格式 |
| NaïveProxy | `naive+https://` | 含 padding 参数 |

---

## 快速开始

### 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/github19999/Odylj/main/install.sh)
```

安装完成后即可直接使用命令：

```bash
sb-sub-gen
```

### 手动安装

```bash
# 安装依赖
apt-get install -y jq python3 coreutils curl

# 下载脚本
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/sb-sub-gen.sh \
  -o /usr/local/bin/sb-sub-gen
chmod +x /usr/local/bin/sb-sub-gen

# 运行
sb-sub-gen
```

---

## 使用方法

```bash
# 使用默认路径
sb-sub-gen

# 自定义配置文件路径
sb-sub-gen /path/to/config.json

# 自定义配置文件 + 输出路径
sb-sub-gen /path/to/config.json /path/to/subscription.txt /path/to/subscription.b64
```

### 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `$1` | `/etc/sing-box/config.json` | sing-box 配置文件路径 |
| `$2` | `/etc/sing-box/subscription.txt` | 明文订阅输出路径 |
| `$3` | `/etc/sing-box/subscription.b64` | Base64 订阅输出路径 |

---

## 输出说明

运行后在终端打印所有生成的订阅链接，同时写入两个文件：

| 文件 | 格式 | 用途 |
|------|------|------|
| `subscription.txt` | 每行一条明文链接 | 手动复制、二次处理 |
| `subscription.b64` | Base64 编码整体 | 直接填入客户端订阅框 |

### 示例输出

```
==========================================
  sing-box 订阅链接生成器
==========================================

[INFO]  服务器 IP: 1.2.3.4
[INFO]  开始解析 inbound 配置...
[INFO]  处理 inbound [0]: type=hysteria2  tag=ve(hk1)-hy2  port=38790
[INFO]  处理 inbound [1]: type=anytls     tag=ve(hk1)-anytls  port=8443
[INFO]  处理 inbound [2]: type=vless      tag=ve(hk1)-vision  port=47790

[INFO]  共生成 3 条订阅链接

==========================================
  所有订阅链接：
==========================================
hysteria2://password@1.2.3.4:38790?sni=example.com&insecure=0&upmbps=100&downmbps=20#ve%28hk1%29-hy2
anytls://password@1.2.3.4:8443?security=tls&sni=example.com&type=tcp#ve%28hk1%29-anytls
vless://uuid@1.2.3.4:47790?encryption=none&flow=xtls-rprx-vision&security=tls&sni=example.com&fp=chrome&type=tcp&headerType=none#ve%28hk1%29-vision
==========================================
```

---

## 配置文件要求

脚本从 sing-box 标准配置文件中读取以下字段，**建议补全 `tag` 和 `tls.server_name`**，否则生成的链接节点名为空、SNI 回退为 IP。

```jsonc
{
  "inbounds": [
    {
      "tag": "ve(hk1)-sb-hy2",          // 节点名称，会成为订阅链接的 # 备注
      "type": "hysteria2",
      "listen": "::",
      "listen_port": 38790,
      "up_mbps": 100,
      "down_mbps": 20,
      "users": [
        { "password": "your-password" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "example.com",   // SNI，缺失时回退为服务器 IP
        "certificate_path": "/etc/ssl/private/fullchain.cer",
        "key_path": "/etc/ssl/private/private.key"
      }
    },
    {
      "tag": "ve(hk1)-sb-vless-reality",
      "type": "vless",
      "listen": "::",
      "listen_port": 443,
      "users": [
        { "uuid": "your-uuid", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "example.com",
        "reality": {
          "enabled": true,
          "public_key": "your-public-key",
          "short_id": "your-short-id"
        },
        "utls": { "fingerprint": "chrome" }
      }
    }
  ],
  "outbounds": [
    { "type": "direct" }
  ]
}
```

> **注意**：配置文件中可以包含 `//` 行注释，脚本会自动清洗后再解析。

---

## 定时自动刷新

一键安装脚本会自动注册 systemd 定时任务，每天凌晨 02:00 重新生成订阅文件。

```bash
# 查看定时任务状态
systemctl status sb-sub-gen.timer

# 手动立即触发一次
systemctl start sb-sub-gen.service

# 查看上次运行日志
journalctl -u sb-sub-gen.service -n 50
```

---

## 依赖

| 工具 | 用途 |
|------|------|
| `jq` | 解析 JSON 配置 |
| `python3` | URL 编码、Base64 VMess 对象生成、注释清洗 |
| `base64` | Shadowsocks 用户信息编码、订阅文件编码 |
| `curl` | 获取服务器公网 IP |

一键安装脚本会自动处理依赖安装（支持 apt / yum / apk）。

---

## 文件结构

```
.
├── sb-sub-gen.sh   # 主脚本：解析配置 → 生成订阅链接
└── install.sh      # 一键安装脚本：安装依赖 + 注册定时任务
```

---

## License

MIT
