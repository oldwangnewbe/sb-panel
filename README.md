# SB Panel

SB Panel 是面向个人和家庭使用的 sing-box 管理面板发行版。

本仓库只提供安装器、使用说明和编译后的发行文件，不包含面板核心源码。发行包内的
sing-box 为官方 `v1.13.12` 源码、在官方 Linux 默认功能集基础上额外启用
`with_v2ray_api` 构建的兼容二进制，用于提供连接管理和每用户流量统计；其源代码与许可证见
[SagerNet/sing-box](https://github.com/SagerNet/sing-box/tree/v1.13.12)。SB Panel 面板
核心仍采用私有发行授权。

## 一键安装

支持使用 systemd 的 Debian、Ubuntu、CentOS、Rocky Linux 和 AlmaLinux，CPU
架构支持 `amd64` 与 `arm64`。

```bash
curl -fsSL https://raw.githubusercontent.com/oldwangnewbe/sb-panel/main/install.sh | sudo bash
```

在交互式终端运行时，安装器会逐项询问并提供默认值：

- 公网域名或 IPv4
- 是否自动申请 Let's Encrypt 证书
- 面板公网端口（默认 `18080`）
- VLESS Reality 公网端口（默认优先 `443`）
- Reality 握手域名、管理员用户名和密码

直接按回车即可使用默认值。即使使用 `curl | sudo bash`，安装器也会通过
`/dev/tty` 正常显示向导。安装完成后会显示面板地址、管理员账号和随机初始密码，
并将凭证保存到：

```text
/root/sb-panel-backups/credentials.txt
```

再次运行同一条命令会备份数据库和配置，然后升级到最新版本。

## HTTPS 与现有 Web 服务

输入域名并选择自动 HTTPS 后，安装器会使用 Let's Encrypt HTTP-01 申请证书，
要求域名已解析且公网 `80/TCP` 可访问。支持以下环境：

- 1Panel 安装的 Docker OpenResty（包括 host 网络模式）
- 普通 Docker OpenResty/Nginx（需要可写的 `conf.d` 持久化挂载）
- 宿主机原生 OpenResty/Nginx
- 尚未安装 Web 服务：自动安装原生 Nginx

已有 Web 服务时使用 Webroot 验证，不会停止服务或抢占 80；没有 Web 服务时才安装
Nginx。所有托管配置都会先备份，写入后执行 `openresty -t` 或 `nginx -t`，失败则
自动恢复。证书续期由 systemd timer 每日检查，续期成功后先校验再重载 Web 服务。

如果目标域名已经出现在现有站点配置中，安装器会停止，避免覆盖原网站。请使用一个
新的面板子域名。

## 无人值守安装

指定公网域名或 IP、面板端口和 VLESS 端口：

```bash
curl -fsSL https://raw.githubusercontent.com/oldwangnewbe/sb-panel/main/install.sh \
  | sudo env SBP_NONINTERACTIVE=1 SBP_PUBLIC_HOST=panel.example.com SBP_TLS=1 \
      SBP_PANEL_PORT=18080 SBP_VLESS_PORT=443 bash
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
| `SBP_PANEL_PORT` | 面板公网端口，默认 `18080` |
| `SBP_PANEL_BACKEND_PORT` | HTTPS 反代使用的内部端口，默认自动选择 18081–18089 |
| `SBP_VLESS_PORT` | VLESS Reality 端口；未指定时优先 443，被占用则使用 34443 |
| `SBP_TLS` | `auto`、`1` 或 `0`；域名默认询问是否自动申请证书 |
| `SBP_TLS_EMAIL` | 可选的 Let's Encrypt 联系邮箱 |
| `SBP_REALITY_SERVER` | Reality 握手目标，默认 `www.apple.com` |
| `SBP_ADMIN_USER` | 初始管理员用户名，默认 `admin` |
| `SBP_ADMIN_PASSWORD` | 自定义初始密码，至少 12 位 |
| `SBP_VERSION` | 安装指定发行版本，默认 `latest` |
| `SBP_NONINTERACTIVE` | 设为 `1` 后完全使用环境变量和默认值，不显示向导 |

## 安全说明

- 安装器不会停止或删除占用 443 的现有网站、代理或其他服务。
- 使用域名时推荐让安装器自动配置 HTTPS；使用 IP 时保持 HTTP，需自行限制访问。
- HTTP-01 只能通过公网 80 完成；防火墙、安全组和上游网络必须允许该端口。
- 完整源码保存在私有仓库；公开发行包不代表源码开放授权。
- 数据库、订阅凭证、TOTP 密钥和落地节点凭证仅应保存在自己的服务器。
- Snell 为每位获授权用户自动分配从 `SNELL_PORT` 开始的独立 TCP 端口；使用主机防火墙或云安全组时，需要允许实际分配的端口。

## 服务与目录

```text
/opt/sb-panel                       程序与数据
/etc/sb-panel/panel.env             服务配置
/etc/sb-panel/sing-box.json         当前生效的 sing-box 配置
/root/sb-panel-backups              凭证与升级备份
sb-panel.service                    面板控制面
sing-box-sb-panel.service           sing-box 数据面
sing-box-sb-panel-apply.path        配置更新监听
snell-sb-panel@.service             每用户独立的官方 Snell 实例
snell-sb-panel-apply.path           Snell 授权撤销与实例同步
sb-panel-cert-renew.timer           HTTPS 证书自动续期（启用 TLS 时）
```

查看状态：

```bash
systemctl status sb-panel sing-box-sb-panel sing-box-sb-panel-apply.path snell-sb-panel-apply.path
```

## 授权

SB Panel 为非开源发行软件。详情见 [LICENSE](LICENSE)。
