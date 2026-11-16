#!/usr/bin/env bash
# =============================================================================
# mynode — personal one-link installer for a VPS
# Installs sing-box with exactly two inbounds on one domain:
#   * Hysteria2            (UDP 443, TLS + salamander obfs)
#   * VLESS + WS + TLS     (TCP 443)
# Certificate: Let's Encrypt via acme.sh (HTTP-01 standalone, needs port 80).
#
# Usage:
#   bash install.sh <your-domain> [email-for-acme]
#   bash install.sh links          # re-print the share links
#
# Re-running keeps the same UUID / passwords / WS path (stored in
# /etc/mynode/creds.env), so your client links never change on reinstall.
# =============================================================================
set -euo pipefail

CONF_DIR=/etc/mynode
CERT_DIR=$CONF_DIR/cert
CREDS=$CONF_DIR/creds.env
SERVICE=mynode
SB_BIN=/usr/local/bin/sing-box

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }

print_links() {
  # shellcheck disable=SC1090
  . "$CREDS"
  local enc_path
  enc_path=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$WS_PATH")
  grn  "==================== 节点链接（保存好） ===================="
  echo "HY2   : hy2://${HY2_PASS}@${DOMAIN}:443?obfs=salamander&obfs-password=${OBFS_PASS}&sni=${DOMAIN}&insecure=0#HY2-${DOMAIN}"
  echo "VLESS : vless://${UUID}@${DOMAIN}:443?security=tls&type=ws&host=${DOMAIN}&sni=${DOMAIN}&path=${enc_path}&encryption=none#VLESS-${DOMAIN}"
  grn  "=============================================================="
  echo "链接同时保存在 /root/mynode-links.txt ，随时可跑: bash install.sh links"
}

if [[ "${1:-}" == "links" ]]; then
  [[ -f $CREDS ]] || { red "还没安装过，没有凭据文件 $CREDS"; exit 1; }
  print_links
  exit 0
fi

DOMAIN="${1:-}"
ACME_EMAIL="${2:-}"
[[ -n "$DOMAIN" ]] || { red "用法: bash install.sh <你的域名> [邮箱]"; exit 1; }
[[ $EUID -eq 0 ]] || { red "请用 root 运行"; exit 1; }

# ---------------------------------------------------------------- OS / deps
. /etc/os-release
case "${ID:-}" in
  debian|ubuntu) ;;
  *) red "只支持 Debian / Ubuntu（当前: ${ID:-unknown}）"; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl jq openssl socat cron python3 ca-certificates >/dev/null

# ---------------------------------------------------------------- sing-box
if [[ ! -x $SB_BIN ]]; then
  arch=$(uname -m)
  case "$arch" in
    x86_64)  sb_arch=amd64 ;;
    aarch64) sb_arch=arm64 ;;
    *) red "不支持的架构: $arch"; exit 1 ;;
  esac
  ver=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
  [[ -n "$ver" && "$ver" != "null" ]] || { red "拿不到 sing-box 最新版本号"; exit 1; }
  vnum="${ver#v}"
  tmp=$(mktemp -d)
  curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${vnum}-linux-${sb_arch}.tar.gz" -o "$tmp/sb.tar.gz"
  tar -xzf "$tmp/sb.tar.gz" -C "$tmp"
  install -m 755 "$tmp/sing-box-${vnum}-linux-${sb_arch}/sing-box" "$SB_BIN"
  rm -rf "$tmp"
  grn "sing-box $ver 已安装"
else
  grn "sing-box 已存在: $($SB_BIN version | head -1)"
fi

# ---------------------------------------------------------------- credentials
mkdir -p "$CONF_DIR" "$CERT_DIR"
if [[ -f $CREDS ]]; then
  . "$CREDS"
  # domain may change between runs; keep secrets, update domain
  if [[ "$DOMAIN" != "${DOMAIN_SAVED:-}" ]]; then
    ylw "域名由 ${DOMAIN_SAVED:-无} 改为 $DOMAIN（UUID/密码保持不变）"
  fi
else
  UUID=$(cat /proc/sys/kernel/random/uuid)
  HY2_PASS=$(openssl rand -hex 12)
  OBFS_PASS=$(openssl rand -hex 12)
  WS_PATH="/$(openssl rand -hex 5)"
fi
cat > "$CREDS" <<EOF
DOMAIN_SAVED=$DOMAIN
DOMAIN=$DOMAIN
UUID=$UUID
HY2_PASS=$HY2_PASS
OBFS_PASS=$OBFS_PASS
WS_PATH=$WS_PATH
EOF
chmod 600 "$CREDS"

# ---------------------------------------------------------------- certificate
if ss -tlnp 2>/dev/null | grep -q ':80 '; then
  ylw "注意: 80 端口已被占用，acme 签发可能会失败。若是旧服务的 nginx 占着，先停掉它再重跑本脚本。"
fi
if [[ ! -x ~/.acme.sh/acme.sh ]]; then
  if [[ -n "$ACME_EMAIL" ]]; then
    curl -fsSL https://get.acme.sh | sh -s email="$ACME_EMAIL"
  else
    curl -fsSL https://get.acme.sh | sh
  fi
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
if [[ ! -s $CERT_DIR/cert.pem ]]; then
  ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256
fi
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file "$CERT_DIR/key.pem" \
  --fullchain-file "$CERT_DIR/cert.pem" \
  --reloadcmd "systemctl restart $SERVICE" >/dev/null
grn "证书就绪: $CERT_DIR/cert.pem"

# ---------------------------------------------------------------- config
cat > "$CONF_DIR/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 443,
      "users": [ { "password": "$HY2_PASS" } ],
      "obfs": { "type": "salamander", "password": "$OBFS_PASS" },
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "$CERT_DIR/cert.pem",
        "key_path": "$CERT_DIR/key.pem"
      }
    },
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": 443,
      "users": [ { "uuid": "$UUID" } ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "$CERT_DIR/cert.pem",
        "key_path": "$CERT_DIR/key.pem"
      },
      "transport": { "type": "ws", "path": "$WS_PATH" }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": { "final": "direct" }
}
EOF
"$SB_BIN" check -c "$CONF_DIR/config.json"
grn "配置校验通过"

# ---------------------------------------------------------------- service
cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=mynode (sing-box: HY2 + VLESS)
After=network.target nss-lookup.target

[Service]
ExecStart=$SB_BIN run -c $CONF_DIR/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now "$SERVICE"

# firewall (best effort)
if command -v ufw >/dev/null && ufw status | grep -qi active; then
  ufw allow 443/tcp >/dev/null || true
  ufw allow 443/udp >/dev/null || true
  ufw allow 80/tcp  >/dev/null || true
fi

sleep 1
systemctl is-active --quiet "$SERVICE" && grn "服务运行中" || { red "服务没起来，看日志: journalctl -u $SERVICE -n 50"; exit 1; }

# ---------------------------------------------------------------- links out
. "$CREDS"
enc_path=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$WS_PATH")
{
  echo "hy2://${HY2_PASS}@${DOMAIN}:443?obfs=salamander&obfs-password=${OBFS_PASS}&sni=${DOMAIN}&insecure=0#HY2-${DOMAIN}"
  echo "vless://${UUID}@${DOMAIN}:443?security=tls&type=ws&host=${DOMAIN}&sni=${DOMAIN}&path=${enc_path}&encryption=none#VLESS-${DOMAIN}"
} > /root/mynode-links.txt
print_links
