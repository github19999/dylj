#!/bin/bash
# =============================================================
# sing-box 订阅生成器 — 一键安装脚本
# 用法: bash <(curl -fsSL https://你的raw地址/install.sh)
# =============================================================

set -euo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/github19999/dylj/main/sb-sub-gen.sh"
INSTALL_PATH="/usr/local/bin/sb-sub-gen"
SERVICE_NAME="sb-sub-gen"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   sing-box 订阅链接生成器  安装程序       ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ─── root 检查 ───────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "请以 root 运行此脚本"

# ─── 安装依赖 ────────────────────────────────────────────────
info "检查并安装依赖 (jq python3 coreutils curl)..."
if command -v apt-get &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq jq python3 coreutils curl
elif command -v yum &>/dev/null; then
    yum install -y -q jq python3 coreutils curl
elif command -v apk &>/dev/null; then
    apk add -q jq python3 coreutils curl
else
    warn "无法自动安装依赖，请手动安装: jq python3 coreutils curl"
fi

# ─── 下载主脚本 ──────────────────────────────────────────────
info "下载主脚本..."
curl -fsSL "$SCRIPT_URL" -o "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"
info "已安装到 $INSTALL_PATH"

# ─── 立即运行一次 ────────────────────────────────────────────
info "立即生成订阅链接..."
"$INSTALL_PATH" || warn "首次运行失败，请检查 /etc/sing-box/config.json"

# ─── 可选：注册 systemd 定时任务（每天凌晨2点刷新） ──────────
if command -v systemctl &>/dev/null; then
    info "注册 systemd 定时任务（每天 02:00 自动刷新订阅）..."

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=sing-box subscription link generator
After=network.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH}
StandardOutput=journal
StandardError=journal
EOF

    cat > "/etc/systemd/system/${SERVICE_NAME}.timer" <<EOF
[Unit]
Description=Run sing-box subscription generator daily

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}.timer"
    info "定时任务已启用"
else
    warn "systemd 不可用，跳过定时任务注册"
fi

echo ""
echo "=========================================="
echo "  安装完成！"
echo ""
echo "  手动执行：sb-sub-gen"
echo "  明文订阅：/etc/sing-box/subscription.txt"
echo "  Base64：  /etc/sing-box/subscription.b64"
echo "=========================================="
echo ""
