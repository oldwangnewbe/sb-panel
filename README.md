# SB Panel

SB Panel 是面向个人和家庭使用的 sing-box 管理面板发行版。

本仓库只提供安装器、使用说明和编译后的发行文件，不包含面板核心源码。

## 一键安装

支持使用 systemd 的 Debian、Ubuntu、CentOS、Rocky Linux 和 AlmaLinux，CPU
架构支持 `amd64` 与 `arm64`。

```bash
curl -fsSL https://raw.githubusercontent.com/oldwangnewbe/sb-panel/main/install.sh | sudo bash
```

安装完成后会显示面板地址、管理员账号和随机初始密码，并将凭证保存到：

```text
/root/sb-panel-backups/credentials.txt
```

再次运行同一条命令会备份数据库和配置，然后升级到最新版本。

## 可选参数

指定公网域名或 IP、面板端口和 VLESS 端口：

```bash
curl -fsSL https://raw.githubusercontent.com/oldwangnewbe/sb-panel/main/install.sh \
  | sudo env SBP_PUBLIC_HOST=panel.example.com SBP_PANEL_PORT=18080 SBP_VLESS_PORT=443 bash
```

安装指定版本：

```bash
curl -fsSL https://raw.githubusercontent.com/oldwangnewbe/sb-panel/main/install.sh \
  | sudo env SBP_VERSION=v0.1.0 bash
```

常用变量：

| 变量 | 说明 |
| --- | --- |
| `SBP_PUBLIC_HOST` | 节点和订阅使用的公网域名或 IPv4 |
| `SBP_PUBLIC_BASE_URL` | 完整公开面板地址，例如 `https://panel.example.com:18080` |
| `SBP_PANEL_PORT` | 面板监听端口，默认自动选择 18080–18082 |
| `SBP_VLESS_PORT` | VLESS Reality 端口；未指定时优先 443，被占用则使用 34443 |
| `SBP_REALITY_SERVER` | Reality 握手目标，默认 `www.apple.com` |
| `SBP_ADMIN_USER` | 初始管理员用户名，默认 `admin` |
| `SBP_ADMIN_PASSWORD` | 自定义初始密码，至少 12 位 |
| `SBP_VERSION` | 安装指定发行版本，默认 `latest` |

## 安全说明

- 安装器不会停止或删除占用 443 的现有网站、代理或其他服务。
- 初始面板使用 HTTP，方便首次进入。公开使用前请配置 HTTPS，并启用两步验证。
- 完整源码保存在私有仓库；公开发行包不代表源码开放授权。
- 数据库、订阅凭证、TOTP 密钥和落地节点凭证仅应保存在自己的服务器。

## 服务与目录

```text
/opt/sb-panel                       程序与数据
/etc/sb-panel/panel.env             服务配置
/etc/sb-panel/sing-box.json         当前生效的 sing-box 配置
/root/sb-panel-backups              凭证与升级备份
sb-panel.service                    面板控制面
sing-box-sb-panel.service           sing-box 数据面
sing-box-sb-panel-apply.path        配置更新监听
```

查看状态：

```bash
systemctl status sb-panel sing-box-sb-panel sing-box-sb-panel-apply.path
```

## 授权

SB Panel 为非开源发行软件。详情见 [LICENSE](LICENSE)。
