#!/usr/bin/env bash
# =============================================================================
# mynode — personal one-link installer for a VPS
# Installs sing-box with exactly two inbounds on one domain:
#   * Hysteria2            (UDP 443, TLS + salamander obfs)
#   * VLESS + WS + TLS     (TCP 443)
# TCP 443 is fronted by nginx: it serves a small decoy website to normal
# browsers and reverse-proxies only the secret WS path to sing-box
# (VLESS then listens on 127.0.0.1:10001, plain WS, no public port).
# Client links are unchanged by this: same domain, port, path and TLS.
# Optional: if a Cloudflare WARP proxy is already running locally in
# socks mode on 127.0.0.1:40000 (warp-cli, e.g. a Zero Trust team
# registration), two extra -WARP inbounds are added on port 8443
# (HY2 UDP + VLESS TCP) whose traffic exits through WARP.
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
  echo ""
  grn "=================================================================="
  grn "  安装完成！下面是你的节点链接（相当于钥匙，请勿外传）"
  grn "=================================================================="
  echo ""
  echo "【HY2 节点】（速度优先，日常主力用这个）"
  echo "hy2://${HY2_PASS}@${DOMAIN}:443?obfs=salamander&obfs-password=${OBFS_PASS}&sni=${DOMAIN}&insecure=0#HY2-${DOMAIN}"
  echo ""
  echo "【VLESS 节点】（备用，兼容性好）"
  echo "vless://${UUID}@${DOMAIN}:443?security=tls&type=ws&host=${DOMAIN}&sni=${DOMAIN}&path=${enc_path}&encryption=none#VLESS-${DOMAIN}"
  if [[ "${WARP:-0}" == "1" ]]; then
    echo ""
    echo "【HY2-WARP 节点】（8443，出口走 Cloudflare 团队 WARP）"
    echo "hy2://${HY2_PASS}@${DOMAIN}:8443?obfs=salamander&obfs-password=${OBFS_PASS}&sni=${DOMAIN}&insecure=0#HY2-WARP-${DOMAIN}"
    echo ""
    echo "【VLESS-WARP 节点】（8443，出口走 Cloudflare 团队 WARP）"
    echo "vless://${UUID}@${DOMAIN}:8443?security=tls&type=ws&host=${DOMAIN}&sni=${DOMAIN}&path=${enc_path}&encryption=none#VLESS-WARP-${DOMAIN}"
  fi
  echo ""
  ylw "使用方法：复制整条链接 → 打开 V2RayN → 菜单「服务器」→「从剪贴板导入批量URL」"
  ylw "链接备份在 VPS 的 /root/mynode-links.txt ，以后随时查看：bash install.sh links"
  ylw "服务管理：systemctl status mynode（状态） / systemctl restart mynode（重启）"
  ylw "提醒：这个域名不要开 Cloudflare 橙云（小云朵保持灰色），否则节点会连不上；"
  ylw "      证书由 acme.sh 自动续期，不用你操心。"
  ylw "伪装站：用浏览器打开 https://${DOMAIN} 会看到一个普通英文博客页面，"
  ylw "      这是故意挂的伪装，节点入口藏在只有你知道的路径后面。"
  grn "=================================================================="
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

grn "=================================================================="
grn "  mynode 个人节点安装开始"
grn "  域名：$DOMAIN（HY2 + VLESS，两个节点共用这一个域名）"
grn "=================================================================="

echo "【1/6】安装依赖软件（curl、jq 等），刷屏是正常的，等它跑完……"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl jq openssl socat cron python3 ca-certificates nginx >/dev/null
# nginx may auto-start with its default site on port 80, which would block
# the acme.sh standalone issuance below; it is configured and (re)started
# properly in step 5, so keep it stopped for now.
systemctl stop nginx 2>/dev/null || true
echo "依赖安装完成。"

# ---------------------------------------------------------------- sing-box
echo "【2/6】安装 sing-box 内核……"
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

# ---------------------------------------------------------------- WARP detect
# warp-cli in proxy mode listens on 127.0.0.1:40000 (socks5). If it is
# there, we add the two -WARP inbounds; if not, install stays 2-inbound.
WARP_ON=0
if (exec 3<>/dev/tcp/127.0.0.1/40000) 2>/dev/null; then
  exec 3>&- 3<&- || true
  WARP_ON=1
  grn "检测到本地 WARP 代理 (127.0.0.1:40000)：将额外添加 8443 的 HY2-WARP / VLESS-WARP 两个入口（出口走 WARP）。"
else
  echo "未检测到本地 WARP 代理 (127.0.0.1:40000)：只装直连的两个入口。以后连上 WARP 再重跑本脚本即可补上。"
fi

# ---------------------------------------------------------------- credentials
echo "【3/6】准备节点凭据（UUID 和密码）……"
mkdir -p "$CONF_DIR" "$CERT_DIR"
if [[ -f $CREDS ]]; then
  echo "检测到已有凭据：沿用原来的 UUID/密码，重装不会让你的客户端链接失效。"
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
WARP=$WARP_ON
EOF
chmod 600 "$CREDS"

# ---------------------------------------------------------------- certificate
echo "【4/6】申请 Let's Encrypt 证书……"
ylw "提醒：接下来会刷出一大段英文，那是证书工具 acme.sh 的正常日志，"
ylw "      你不用看懂，看到「Cert success」就是证书签下来了。"
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
  --reloadcmd "systemctl restart $SERVICE || true; systemctl reload nginx || true" >/dev/null || true
grn "证书环节结束，证书已就绪: $CERT_DIR/cert.pem"

# ---------------------------------------------------------------- config
echo "【5/6】写入节点配置、伪装网站并启动服务……"
WARP_INBOUNDS=""
WARP_OUTBOUND=""
WARP_RULES=""
if [[ "$WARP_ON" == "1" ]]; then
  WARP_INBOUNDS=$(cat <<WJSON
,
    {
      "type": "hysteria2",
      "tag": "hy2-warp-in",
      "listen": "::",
      "listen_port": 8443,
      "up_mbps": 1000,
      "down_mbps": 1000,
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
      "tag": "vless-warp-in",
      "listen": "::",
      "listen_port": 8443,
      "users": [ { "uuid": "$UUID" } ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "$CERT_DIR/cert.pem",
        "key_path": "$CERT_DIR/key.pem"
      },
      "transport": { "type": "ws", "path": "$WS_PATH" }
    }
WJSON
)
  WARP_OUTBOUND=', { "type": "socks", "tag": "warp", "server": "127.0.0.1", "server_port": 40000 }'
  WARP_RULES=', "rules": [ { "inbound": ["hy2-warp-in", "vless-warp-in"], "outbound": "warp" } ]'
fi
cat > "$CONF_DIR/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 443,
      "up_mbps": 1000,
      "down_mbps": 1000,
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
      "listen": "127.0.0.1",
      "listen_port": 10001,
      "users": [ { "uuid": "$UUID" } ],
      "transport": { "type": "ws", "path": "$WS_PATH" }
    }$WARP_INBOUNDS
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" }$WARP_OUTBOUND ],
  "route": { "final": "direct"$WARP_RULES }
}
EOF
"$SB_BIN" check -c "$CONF_DIR/config.json"
grn "配置校验通过"

# ---------------------------------------------------------------- decoy site + nginx front
# nginx owns public TCP 443: browsers get a small static site; only the
# exact secret WS path is proxied to sing-box on 127.0.0.1:10001.
SITE_DIR=/var/www/mynode-site
mkdir -p "$SITE_DIR"
# nginx workers (www-data) must be able to read the site regardless of umask
chmod 755 "$SITE_DIR"
cat > "$SITE_DIR/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Fieldnotes — systems, networks, and other curiosities</title>
<style>
  body { font-family: Georgia, 'Times New Roman', serif; color: #222; background: #fdfdfa;
         max-width: 44rem; margin: 0 auto; padding: 2.5rem 1.25rem 4rem; line-height: 1.65; }
  header { border-bottom: 2px solid #222; padding-bottom: 1rem; margin-bottom: 2rem; }
  header h1 { font-size: 1.9rem; margin: 0; letter-spacing: .02em; }
  header p { color: #666; margin: .3rem 0 0; font-style: italic; }
  nav { margin-top: .8rem; font-size: .95rem; }
  nav a { color: #14532d; margin-right: 1.2rem; text-decoration: none; }
  nav a:hover { text-decoration: underline; }
  article { margin-bottom: 2.2rem; }
  article h2 { font-size: 1.25rem; margin: 0 0 .2rem; }
  article h2 a { color: #222; text-decoration: none; }
  article h2 a:hover { text-decoration: underline; }
  .meta { color: #888; font-size: .85rem; margin-bottom: .4rem; }
  footer { border-top: 1px solid #ccc; margin-top: 3rem; padding-top: 1rem;
           color: #888; font-size: .85rem; }
</style>
</head>
<body>
<header>
  <h1>Fieldnotes</h1>
  <p>Occasional notes on systems, networks, and other curiosities.</p>
  <nav><a href="/">Home</a><a href="/">Archive</a><a href="/">About</a></nav>
</header>
<main>
  <article>
    <h2><a href="/">Notes on running a small home lab in 2026</a></h2>
    <div class="meta">November 2, 2026 · 6 min read</div>
    <p>Every few years I rebuild my home lab from scratch, mostly to see which of my
    old assumptions still hold. This time the surprise was how far a single low-power
    box and a couple of containers will take you before you actually need a rack.</p>
  </article>
  <article>
    <h2><a href="/">What I check first when a server feels slow</a></h2>
    <div class="meta">October 18, 2026 · 4 min read</div>
    <p>Most "the server is slow" reports turn out to be one of three things: a disk
    quietly failing, a backup job colliding with peak hours, or DNS. A short checklist
    I run before touching anything else, in the order I actually run it.</p>
  </article>
  <article>
    <h2><a href="/">Backups are a restore you have not tested yet</a></h2>
    <div class="meta">September 30, 2026 · 5 min read</div>
    <p>A backup schedule is a promise; a restore drill is the evidence. Some notes on
    keeping off-site copies boring, encrypted, and — above all — regularly rehearsed,
    so the worst day does not become an improvisation exercise.</p>
  </article>
</main>
<footer>© 2026 Fieldnotes · Built by hand, hosted on a small machine that minds its own business.</footer>
</body>
</html>
HTML
cat > "$SITE_DIR/404.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>404 — Fieldnotes</title>
<style>
  body { font-family: Georgia, 'Times New Roman', serif; color: #222; background: #fdfdfa;
         max-width: 44rem; margin: 0 auto; padding: 4rem 1.25rem; line-height: 1.65; text-align: center; }
  a { color: #14532d; }
</style>
</head>
<body>
  <h1>404</h1>
  <p>That page wandered off. <a href="/">Back to the front page</a>.</p>
</body>
</html>
HTML
chmod 644 "$SITE_DIR"/index.html "$SITE_DIR"/404.html

cat > /etc/nginx/sites-available/mynode <<'NGINX'
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name __DOMAIN__;

    ssl_certificate     /etc/mynode/cert/cert.pem;
    ssl_certificate_key /etc/mynode/cert/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    server_tokens       off;

    root  /var/www/mynode-site;
    index index.html;

    location = __WS_PATH__ {
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location / {
        try_files $uri $uri/ =404;
    }
    error_page 404 /404.html;
    location = /404.html { internal; }
}
NGINX
sed -i "s|__DOMAIN__|$DOMAIN|g; s|__WS_PATH__|$WS_PATH|g" /etc/nginx/sites-available/mynode
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/mynode
ln -s /etc/nginx/sites-available/mynode /etc/nginx/sites-enabled/mynode
nginx -t
grn "伪装站与 nginx 前置已就绪（443 由 nginx 接管，VLESS 藏到本机 10001）"

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
# explicit restart: guarantees the freshly written config is the running
# one on re-runs, and frees public TCP 443 before nginx takes it over.
systemctl restart "$SERVICE"
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx

# firewall (best effort)
if command -v ufw >/dev/null && ufw status | grep -qi active; then
  ufw allow 443/tcp >/dev/null || true
  ufw allow 443/udp >/dev/null || true
  ufw allow 80/tcp  >/dev/null || true
  if [[ "$WARP_ON" == "1" ]]; then
    ufw allow 8443/tcp >/dev/null || true
    ufw allow 8443/udp >/dev/null || true
  fi
fi

sleep 1
systemctl is-active --quiet "$SERVICE" && systemctl is-active --quiet nginx && grn "服务已启动并正在运行（sing-box + nginx 伪装站）。" || { red "服务没起来，看日志: journalctl -u $SERVICE -n 50 以及 systemctl status nginx"; exit 1; }
echo "【6/6】全部完成，节点链接如下："

# ---------------------------------------------------------------- links out
. "$CREDS"
enc_path=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$WS_PATH")
{
  echo "hy2://${HY2_PASS}@${DOMAIN}:443?obfs=salamander&obfs-password=${OBFS_PASS}&sni=${DOMAIN}&insecure=0#HY2-${DOMAIN}"
  echo "vless://${UUID}@${DOMAIN}:443?security=tls&type=ws&host=${DOMAIN}&sni=${DOMAIN}&path=${enc_path}&encryption=none#VLESS-${DOMAIN}"
  if [[ "$WARP_ON" == "1" ]]; then
    echo "hy2://${HY2_PASS}@${DOMAIN}:8443?obfs=salamander&obfs-password=${OBFS_PASS}&sni=${DOMAIN}&insecure=0#HY2-WARP-${DOMAIN}"
    echo "vless://${UUID}@${DOMAIN}:8443?security=tls&type=ws&host=${DOMAIN}&sni=${DOMAIN}&path=${enc_path}&encryption=none#VLESS-WARP-${DOMAIN}"
  fi
} > /root/mynode-links.txt
print_links
