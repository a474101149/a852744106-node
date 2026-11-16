# mynode — 个人一键安装脚本

在自己的 VPS 上装一个只属于自己的节点服务：sing-box 内核，只开两个协议，绑定自己的域名。

- **Hysteria2**（UDP 443，TLS + salamander 混淆）
- **VLESS + WS + TLS**（TCP 443）
- 证书：acme.sh 自动申请 Let's Encrypt（HTTP-01），自动续期
- 重跑脚本不换 UUID/密码，客户端链接保持不变（凭据存 `/etc/mynode/creds.env`）

## 使用

前置条件：Debian / Ubuntu、root、域名 A 记录已解析到这台 VPS（DNS only，不要开橙云）、80 和 443 端口空闲。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/a474101149/a852744106-node/main/install.sh) 你的域名
```

装完终端会打印两条节点链接，也保存在 VPS 的 `/root/mynode-links.txt`。

随时重新打印链接：

```bash
bash install.sh links
```

## 管理

- 服务名：`mynode`（`systemctl status/restart mynode`）
- 配置：`/etc/mynode/config.json`
- 日志：`journalctl -u mynode -f`
