#!/usr/bin/env bash
set -Eeuo pipefail

RELEASE_REPO=${SBP_RELEASE_REPO:-oldwangnewbe/sb-panel}
VERSION=${SBP_VERSION:-latest}
SING_BOX_VERSION=${SBP_SING_BOX_VERSION:-1.13.12}
APP_ROOT=/opt/sb-panel
BIN_DIR=${APP_ROOT}/bin
DATA_DIR=${APP_ROOT}/data
CONFIG_DIR=/etc/sb-panel
ENV_FILE=${CONFIG_DIR}/panel.env
PANEL_BIN=${BIN_DIR}/sb-panel
SING_BOX_BIN=${BIN_DIR}/sing-box
ACTIVE_CONFIG=${CONFIG_DIR}/sing-box.json
BACKUP_ROOT=/root/sb-panel-backups
DRY_RUN=${SBP_DRY_RUN:-0}

log() { printf '\033[1;35m[SB Panel]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[SB Panel]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[SB Panel]\033[0m %s\n' "$*" >&2; exit 1; }

if [[ ${DRY_RUN} != 1 && ${EUID} -ne 0 ]]; then
  die "请使用 root 运行：curl -fsSL https://raw.githubusercontent.com/${RELEASE_REPO}/main/install.sh | sudo bash"
fi
if [[ $(uname -s) != Linux ]]; then
  die "一键安装器目前只支持 Linux。"
fi
if [[ ${DRY_RUN} != 1 ]] && ! command -v systemctl >/dev/null 2>&1; then
  die "当前系统没有 systemd，暂不支持一键安装。"
fi

case $(uname -m) in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "暂不支持的 CPU 架构：$(uname -m)" ;;
esac

install_dependencies() {
  local missing=0
  for command in curl tar jq openssl flock ss sha256sum; do
    command -v "${command}" >/dev/null 2>&1 || missing=1
  done
  [[ ${missing} -eq 0 ]] && return
  log "安装运行依赖"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl tar jq openssl util-linux iproute2 passwd
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl tar jq openssl util-linux iproute shadow-utils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl tar jq openssl util-linux iproute shadow-utils
  else
    die "无法自动安装依赖，请先安装 curl、tar、jq、openssl、flock、ss 和 sha256sum。"
  fi
}

if [[ ${DRY_RUN} != 1 ]]; then
  install_dependencies
else
  command -v curl >/dev/null 2>&1 || die "缺少 curl"
  command -v sha256sum >/dev/null 2>&1 || die "缺少 sha256sum"
fi

TMP_DIR=$(mktemp -d /tmp/sb-panel-install.XXXXXX)
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

if [[ ${VERSION} == latest ]]; then
  RELEASE_BASE="https://github.com/${RELEASE_REPO}/releases/latest/download"
else
  [[ ${VERSION} =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || die "SBP_VERSION 格式无效：${VERSION}"
  RELEASE_BASE="https://github.com/${RELEASE_REPO}/releases/download/${VERSION}"
fi
PANEL_ASSET=sb-panel-linux-${ARCH}

download() {
  local url=$1 target=$2
  curl --fail --location --silent --show-error --retry 3 --connect-timeout 12 --output "${target}" "${url}"
}

log "下载 SB Panel ${VERSION} (${ARCH})"
download "${RELEASE_BASE}/${PANEL_ASSET}" "${TMP_DIR}/${PANEL_ASSET}"
download "${RELEASE_BASE}/checksums.txt" "${TMP_DIR}/checksums.txt"
expected=$(awk -v file="${PANEL_ASSET}" '$2 == file {print $1}' "${TMP_DIR}/checksums.txt")
[[ ${expected} =~ ^[0-9a-fA-F]{64}$ ]] || die "发布包缺少有效校验值。"
actual=$(sha256sum "${TMP_DIR}/${PANEL_ASSET}" | awk '{print $1}')
[[ ${actual} == "${expected}" ]] || die "下载文件校验失败，安装已停止。"
chmod 0755 "${TMP_DIR}/${PANEL_ASSET}"

if [[ ${DRY_RUN} == 1 ]]; then
  log "检查通过：发布包可下载，SHA-256 校验正确。"
  printf 'repository=%s\nversion=%s\narchitecture=%s\nmode=%s\n' \
    "${RELEASE_REPO}" "${VERSION}" "${ARCH}" "$([[ -x ${PANEL_BIN} ]] && echo upgrade || echo install)"
  exit 0
fi

wait_for_health() {
  local port=$1
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

panel_port_from_env() {
  local listen
  listen=$(awk -F= '$1 == "PANEL_LISTEN" {print $2; exit}' "${ENV_FILE}")
  listen=${listen:-0.0.0.0:18080}
  printf '%s\n' "${listen##*:}"
}

upgrade_existing() {
  local stamp backup panel_port core_pid_before core_pid_after
  stamp=$(date -u +%Y%m%d-%H%M%S)
  backup=${BACKUP_ROOT}/${stamp}-release-upgrade
  panel_port=$(panel_port_from_env)
  core_pid_before=$(tr -cd '0-9' </run/sb-panel-sing-box/main.pid 2>/dev/null || true)
  install -d -m 0700 "${backup}"
  systemctl stop sb-panel.service
  cp -a "${PANEL_BIN}" "${backup}/sb-panel"
  cp -a "${ENV_FILE}" "${backup}/panel.env"
  [[ ! -f ${DATA_DIR}/panel.db ]] || cp -a "${DATA_DIR}/panel.db" "${backup}/panel.db"
  [[ ! -f ${DATA_DIR}/sing-box.json ]] || cp -a "${DATA_DIR}/sing-box.json" "${backup}/sing-box.candidate.json"
  [[ ! -f ${ACTIVE_CONFIG} ]] || cp -a "${ACTIVE_CONFIG}" "${backup}/sing-box.active.json"
  install -o root -g root -m 0755 "${TMP_DIR}/${PANEL_ASSET}" "${PANEL_BIN}"
  if ! systemctl start sb-panel.service || ! wait_for_health "${panel_port}"; then
    warn "升级健康检查失败，正在恢复旧版本。"
    systemctl stop sb-panel.service >/dev/null 2>&1 || true
    install -o root -g root -m 0755 "${backup}/sb-panel" "${PANEL_BIN}"
    systemctl start sb-panel.service
    die "升级失败，已恢复。备份：${backup}"
  fi
  core_pid_after=$(tr -cd '0-9' </run/sb-panel-sing-box/main.pid 2>/dev/null || true)
  if [[ -n ${core_pid_before} && ${core_pid_before} != "${core_pid_after}" ]]; then
    warn "面板升级后 sing-box PID 发生变化，请检查服务日志。"
  fi
  log "升级完成：$(${PANEL_BIN} version)"
  log "备份目录：${backup}"
}

if [[ -x ${PANEL_BIN} && -f ${ENV_FILE} ]]; then
  upgrade_existing
  exit 0
fi

port_in_use() {
  local port=$1
  ss -H -ltn | awk '{print $4}' | grep -Eq "(^|:|\\])${port}$"
}

choose_panel_port() {
  if [[ -n ${SBP_PANEL_PORT:-} ]]; then
    [[ ${SBP_PANEL_PORT} =~ ^[0-9]+$ ]] && ((SBP_PANEL_PORT >= 1 && SBP_PANEL_PORT <= 65535)) || die "SBP_PANEL_PORT 无效。"
    port_in_use "${SBP_PANEL_PORT}" && die "面板端口 ${SBP_PANEL_PORT} 已被占用。"
    printf '%s\n' "${SBP_PANEL_PORT}"
    return
  fi
  local candidate
  for candidate in 18080 18081 18082; do
    if ! port_in_use "${candidate}"; then printf '%s\n' "${candidate}"; return; fi
  done
  die "18080–18082 均已占用，请用 SBP_PANEL_PORT 指定端口。"
}

choose_vless_port() {
  if [[ -n ${SBP_VLESS_PORT:-} ]]; then
    [[ ${SBP_VLESS_PORT} =~ ^[0-9]+$ ]] && ((SBP_VLESS_PORT >= 1 && SBP_VLESS_PORT <= 65535)) || die "SBP_VLESS_PORT 无效。"
    port_in_use "${SBP_VLESS_PORT}" && die "节点端口 ${SBP_VLESS_PORT} 已被占用；安装器不会强行停止现有网站或代理。"
    printf '%s\n' "${SBP_VLESS_PORT}"
    return
  fi
  if ! port_in_use 443; then printf '443\n'; return; fi
  if ! port_in_use 34443; then warn "公网 443 已被占用，VLESS 自动改用 34443。"; printf '34443\n'; return; fi
  die "443 和 34443 均已占用，请用 SBP_VLESS_PORT 指定空闲端口。"
}

PANEL_PORT=$(choose_panel_port)
VLESS_PORT=$(choose_vless_port)
PUBLIC_HOST=${SBP_PUBLIC_HOST:-}
if [[ -z ${PUBLIC_HOST} ]]; then
  PUBLIC_HOST=$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
fi
if [[ -z ${PUBLIC_HOST} ]] && command -v hostname >/dev/null 2>&1; then
  PUBLIC_HOST=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
[[ ${PUBLIC_HOST} =~ ^[A-Za-z0-9._-]+$ ]] || die "无法识别公网地址，请用 SBP_PUBLIC_HOST=域名或IPv4 重新运行。"
PUBLIC_BASE_URL=${SBP_PUBLIC_BASE_URL:-http://${PUBLIC_HOST}:${PANEL_PORT}}
[[ ${PUBLIC_BASE_URL} =~ ^https?://[A-Za-z0-9._:-]+$ ]] || die "SBP_PUBLIC_BASE_URL 仅支持 http(s)://主机:端口。"
REALITY_SERVER=${SBP_REALITY_SERVER:-www.apple.com}
[[ ${REALITY_SERVER} =~ ^[A-Za-z0-9.-]+$ ]] || die "SBP_REALITY_SERVER 无效。"
ADMIN_USER=${SBP_ADMIN_USER:-admin}
[[ ${ADMIN_USER} =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "SBP_ADMIN_USER 无效。"
ADMIN_PASSWORD=${SBP_ADMIN_PASSWORD:-$(openssl rand -hex 16)}
(( ${#ADMIN_PASSWORD} >= 12 )) || die "SBP_ADMIN_PASSWORD 至少需要 12 个字符。"
[[ ${ADMIN_PASSWORD} =~ ^[A-Za-z0-9._~!@%^+=:-]+$ ]] || die "SBP_ADMIN_PASSWORD 含有不支持的字符。"

log "安装 sing-box ${SING_BOX_VERSION}"
SING_BOX_ARCHIVE=sing-box-${SING_BOX_VERSION}-linux-${ARCH}.tar.gz
download "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${SING_BOX_ARCHIVE}" "${TMP_DIR}/${SING_BOX_ARCHIVE}"
tar -xzf "${TMP_DIR}/${SING_BOX_ARCHIVE}" -C "${TMP_DIR}"
SING_BOX_SOURCE=$(find "${TMP_DIR}" -type f -name sing-box | head -n 1)
[[ -n ${SING_BOX_SOURCE} ]] || die "sing-box 发布包内容无效。"

if ! id sb-panel >/dev/null 2>&1; then
  useradd --system --home-dir "${APP_ROOT}" --shell /usr/sbin/nologin sb-panel
fi
install -d -o sb-panel -g sb-panel -m 0750 "${APP_ROOT}" "${BIN_DIR}" "${DATA_DIR}"
install -d -o root -g sb-panel -m 0750 "${CONFIG_DIR}"
install -d -m 0700 "${BACKUP_ROOT}"
install -d -m 0755 /usr/local/libexec
install -o root -g root -m 0755 "${TMP_DIR}/${PANEL_ASSET}" "${PANEL_BIN}"
install -o root -g root -m 0755 "${SING_BOX_SOURCE}" "${SING_BOX_BIN}"

umask 077
cat >"${ENV_FILE}" <<EOF
PANEL_DATA_DIR=${DATA_DIR}
PANEL_DB=${DATA_DIR}/panel.db
PANEL_LISTEN=0.0.0.0:${PANEL_PORT}
PANEL_ADMIN_USER=${ADMIN_USER}
PANEL_ADMIN_PASSWORD=${ADMIN_PASSWORD}
PANEL_COOKIE_SECURE=false
PANEL_CORE_MODE=systemd
PANEL_MANAGE_CORE=false
SINGBOX_BIN=${SING_BOX_BIN}
SINGBOX_CONFIG=${DATA_DIR}/sing-box.json
SINGBOX_LOG=${DATA_DIR}/sing-box.log
CORE_APPLY_REQUEST=${DATA_DIR}/core-apply.request
CORE_APPLY_RESULT=${DATA_DIR}/core-apply.result
CORE_PID_FILE=/run/sb-panel-sing-box/main.pid
CORE_APPLY_TIMEOUT=25s
PUBLIC_HOST=${PUBLIC_HOST}
PUBLIC_BASE_URL=${PUBLIC_BASE_URL}
VLESS_PUBLIC_HOST=${PUBLIC_HOST}
VLESS_ENABLED=true
VLESS_PORT=${VLESS_PORT}
VLESS_LISTEN_HOST=0.0.0.0
VLESS_LISTEN_PORT=${VLESS_PORT}
REALITY_SERVER=${REALITY_SERVER}
REALITY_HANDSHAKE_SERVER=${REALITY_SERVER}
REALITY_PORT=443
EOF
chown root:sb-panel "${ENV_FILE}"
chmod 0640 "${ENV_FILE}"

cat >/usr/local/libexec/sb-panel-sing-box-run <<'EOF'
#!/bin/sh
set -eu
umask 027
printf '%s\n' "$$" >/run/sb-panel-sing-box/main.pid
exec /opt/sb-panel/bin/sing-box run -c /etc/sb-panel/sing-box.json
EOF
chmod 0755 /usr/local/libexec/sb-panel-sing-box-run

cat >/usr/local/libexec/sb-panel-sing-box-apply <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
candidate=/opt/sb-panel/data/sing-box.json
request=/opt/sb-panel/data/core-apply.request
result=/opt/sb-panel/data/core-apply.result
active=/etc/sb-panel/sing-box.json
binary=/opt/sb-panel/bin/sing-box
service=sing-box-sb-panel.service
pid_file=/run/sb-panel-sing-box/main.pid
backup_dir=/var/lib/sb-panel-core/backups
lock_file=/run/lock/sb-panel-sing-box-apply.lock
install -d -m 0700 "${backup_dir}"
exec 9>"${lock_file}"
flock -x 9
request_id=
request_hash=
write_result() {
  local ok=$1 error=$2 pid=${3:-0} temp=${result}.next
  jq -n --arg id "${request_id}" --arg hash "${request_hash}" --argjson ok "${ok}" --arg error "${error}" --argjson pid "${pid}" --arg appliedAt "$(date -u +%FT%TZ)" '{id:$id,hash:$hash,ok:$ok,error:$error,pid:$pid,appliedAt:$appliedAt}' >"${temp}"
  chown root:sb-panel "${temp}"; chmod 0640 "${temp}"; mv -f "${temp}" "${result}"
}
fail() { local message=$1; write_result false "${message}" 0; printf '%s\n' "${message}" >&2; exit 1; }
[[ -s ${request} ]] || fail "apply request is missing"
[[ -s ${candidate} ]] || fail "candidate sing-box configuration is missing"
request_id=$(jq -er '.id | select(type == "string" and length > 0)' "${request}") || fail "invalid apply request id"
request_hash=$(jq -er '.hash | select(type == "string" and length == 64)' "${request}") || fail "invalid apply request hash"
check_output=
if ! check_output=$("${binary}" check -c "${candidate}" 2>&1); then fail "sing-box check failed: ${check_output:0:1500}"; fi
stamp=$(date -u +%Y%m%d-%H%M%S)
rollback=${backup_dir}/${stamp}-${request_id}.json
had_active=0
if [[ -s ${active} ]]; then had_active=1; cp -a "${active}" "${rollback}"; chmod 0600 "${rollback}"; fi
install -o root -g sb-panel -m 0640 "${candidate}" "${active}.next"
mv -f "${active}.next" "${active}"
start_error=
if ! start_error=$(systemctl restart "${service}" 2>&1); then start_error="systemctl restart failed: ${start_error}"; fi
healthy=0
if [[ -z ${start_error} ]]; then
  for _ in {1..30}; do
    if systemctl is-active --quiet "${service}" && [[ -s ${pid_file} ]]; then
      pid=$(tr -cd '0-9' <"${pid_file}")
      if [[ -n ${pid} ]] && kill -0 "${pid}" 2>/dev/null; then healthy=1; break; fi
    fi
    sleep 0.2
  done
fi
if [[ ${healthy} -ne 1 ]]; then
  systemctl stop "${service}" >/dev/null 2>&1 || true
  if [[ ${had_active} -eq 1 ]]; then install -o root -g sb-panel -m 0640 "${rollback}" "${active}"; systemctl restart "${service}" || true; fi
  fail "new core failed its health check; ${start_error}"
fi
pid=$(tr -cd '0-9' <"${pid_file}")
write_result true "" "${pid}"
EOF
chmod 0755 /usr/local/libexec/sb-panel-sing-box-apply

cat >/etc/systemd/system/sb-panel.service <<'EOF'
[Unit]
Description=SB Panel control plane
After=network-online.target sing-box-sb-panel.service
Wants=network-online.target sing-box-sb-panel.service

[Service]
Type=simple
User=sb-panel
Group=sb-panel
WorkingDirectory=/opt/sb-panel
EnvironmentFile=/etc/sb-panel/panel.env
ExecStart=/opt/sb-panel/bin/sb-panel
Restart=on-failure
RestartSec=3s
TimeoutStopSec=12s
KillMode=control-group
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
CapabilityBoundingSet=
ReadWritePaths=/opt/sb-panel/data
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/sing-box-sb-panel.service <<'EOF'
[Unit]
Description=sing-box data plane for SB Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=sb-panel
Group=sb-panel
WorkingDirectory=/opt/sb-panel
RuntimeDirectory=sb-panel-sing-box
RuntimeDirectoryMode=0750
ExecStart=/usr/local/libexec/sb-panel-sing-box-run
Restart=on-failure
RestartSec=2s
TimeoutStopSec=12s
KillMode=mixed
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ReadWritePaths=/opt/sb-panel/data
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/sing-box-sb-panel-apply.service <<'EOF'
[Unit]
Description=Validate and atomically apply SB Panel sing-box configuration
After=sing-box-sb-panel.service

[Service]
Type=oneshot
User=root
Group=root
ExecStart=/usr/local/libexec/sb-panel-sing-box-apply
TimeoutStartSec=45s
StateDirectory=sb-panel-core
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
ReadWritePaths=/etc/sb-panel /opt/sb-panel/data /var/lib/sb-panel-core /run/lock
EOF

cat >/etc/systemd/system/sing-box-sb-panel-apply.path <<'EOF'
[Unit]
Description=Watch for SB Panel sing-box apply requests

[Path]
PathChanged=/opt/sb-panel/data/core-apply.request
Unit=sing-box-sb-panel-apply.service

[Install]
WantedBy=multi-user.target
EOF

log "初始化数据库和 sing-box 配置"
set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a
PANEL_CORE_MODE=config-only PANEL_MANAGE_CORE=false "${PANEL_BIN}" bootstrap
"${SING_BOX_BIN}" check -c "${DATA_DIR}/sing-box.json"
chown -R sb-panel:sb-panel "${DATA_DIR}"
find "${DATA_DIR}" -type d -exec chmod 0750 {} +
find "${DATA_DIR}" -type f -exec chmod 0640 {} +
chmod 0600 "${DATA_DIR}/panel.db"
install -o root -g sb-panel -m 0640 "${DATA_DIR}/sing-box.json" "${ACTIVE_CONFIG}"

systemctl daemon-reload
systemctl enable sing-box-sb-panel.service sing-box-sb-panel-apply.path sb-panel.service >/dev/null
systemctl start sing-box-sb-panel.service
systemctl start sing-box-sb-panel-apply.path
systemctl start sb-panel.service
if ! wait_for_health "${PANEL_PORT}"; then
  systemctl status sb-panel.service sing-box-sb-panel.service --no-pager >&2 || true
  die "服务健康检查失败，请查看 journalctl -u sb-panel -u sing-box-sb-panel。"
fi

cat >${BACKUP_ROOT}/credentials.txt <<EOF
SB Panel URL: ${PUBLIC_BASE_URL}
Username: ${ADMIN_USER}
Password: ${ADMIN_PASSWORD}
VLESS port: ${VLESS_PORT}
Installed: $(date -u +%FT%TZ)
EOF
chmod 0600 ${BACKUP_ROOT}/credentials.txt

log "安装完成：$(${PANEL_BIN} version)"
printf '\n访问地址：%s\n管理员：%s\n初始密码：%s\nVLESS 端口：%s\n\n' "${PUBLIC_BASE_URL}" "${ADMIN_USER}" "${ADMIN_PASSWORD}" "${VLESS_PORT}"
warn "首次访问为 HTTP。公开使用前请配置 HTTPS，并在面板中启用两步验证。"
log "凭证已保存到 ${BACKUP_ROOT}/credentials.txt（权限 600）"
