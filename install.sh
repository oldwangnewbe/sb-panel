#!/usr/bin/env bash
set -Eeuo pipefail

RELEASE_REPO=${SBP_RELEASE_REPO:-oldwangnewbe/sb-panel}
VERSION=${SBP_VERSION:-latest}
SING_BOX_VERSION=${SBP_SING_BOX_VERSION:-1.13.12}
ACME_SH_VERSION=${SBP_ACME_SH_VERSION:-3.1.1}
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
NONINTERACTIVE=${SBP_NONINTERACTIVE:-0}
TLS_ENABLED=0
WEB_MODE=
WEB_CONTAINER=
WEB_CONF_HOST=
WEB_CONF_RUNTIME=
WEB_ROOT_HOST=
WEB_ROOT_RUNTIME=
WEB_CERT_HOST=
WEB_CERT_RUNTIME=
WEB_CONFIG_FILE=
WEB_CONFIG_BACKUP=
WEB_PROXY_HOST=127.0.0.1
WEB_BINARY=
WEB_SERVICE=
TLS_ROLLBACK_PENDING=0

log() { printf '\033[1;35m[SB Panel]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[SB Panel]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[SB Panel]\033[0m %s\n' "$*" >&2; exit 1; }

has_tty() { [[ ${NONINTERACTIVE} != 1 && -r /dev/tty && -w /dev/tty ]]; }

prompt() {
  local label=$1 default=${2:-} answer
  if ! has_tty; then
    printf '%s\n' "${default}"
    return
  fi
  if [[ -n ${default} ]]; then
    printf '\033[1;36m%s\033[0m [%s]: ' "${label}" "${default}" >/dev/tty
  else
    printf '\033[1;36m%s\033[0m: ' "${label}" >/dev/tty
  fi
  IFS= read -r answer </dev/tty || answer=
  printf '%s\n' "${answer:-${default}}"
}

prompt_secret() {
  local label=$1 answer
  if ! has_tty; then
    printf '\n'
    return
  fi
  printf '\033[1;36m%s\033[0m（留空则自动生成）: ' "${label}" >/dev/tty
  IFS= read -r -s answer </dev/tty || answer=
  printf '\n' >/dev/tty
  printf '%s\n' "${answer}"
}

confirm() {
  local label=$1 default=${2:-yes} suffix answer
  if ! has_tty; then
    [[ ${default} == yes ]]
    return
  fi
  [[ ${default} == yes ]] && suffix='Y/n' || suffix='y/N'
  printf '\033[1;36m%s\033[0m [%s]: ' "${label}" "${suffix}" >/dev/tty
  IFS= read -r answer </dev/tty || answer=
  answer=${answer:-${default}}
  [[ ${answer,,} == y || ${answer,,} == yes || ${answer} == 是 ]]
}

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
cleanup() {
  local status=$?
  if [[ ${TLS_ROLLBACK_PENDING} == 1 ]] && declare -F rollback_web_config >/dev/null 2>&1; then
    rollback_web_config || true
  fi
  rm -rf "${TMP_DIR}"
  return "${status}"
}
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

valid_port() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
is_ipv4() {
  [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local octet
  local -a octets
  IFS=. read -r -a octets <<<"$1"
  for octet in "${octets[@]}"; do ((10#${octet} <= 255)) || return 1; done
}
is_dns_name() {
  [[ $1 == *.* && $1 != .* && $1 != *. && $1 != *..* ]] || return 1
  local label
  local -a labels
  IFS=. read -r -a labels <<<"$1"
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 && ${label} =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
  (( ${#1} <= 253 ))
}

DETECTED_PUBLIC_IP=$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
if [[ -z ${DETECTED_PUBLIC_IP} ]] && command -v hostname >/dev/null 2>&1; then
  DETECTED_PUBLIC_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
PUBLIC_HOST=${SBP_PUBLIC_HOST:-}
PUBLIC_HOST=$(prompt "公网域名或 IPv4" "${PUBLIC_HOST:-${DETECTED_PUBLIC_IP}}")
[[ ${PUBLIC_HOST} =~ ^[A-Za-z0-9.-]+$ ]] || die "公网地址格式无效。"
is_ipv4 "${PUBLIC_HOST}" || is_dns_name "${PUBLIC_HOST}" || die "请输入有效的域名或 IPv4 地址。"

case ${SBP_TLS:-auto} in
  1|yes|true|on) TLS_ENABLED=1 ;;
  0|no|false|off) TLS_ENABLED=0 ;;
  auto)
    if is_dns_name "${PUBLIC_HOST}" && confirm "为面板自动申请 Let's Encrypt 证书" yes; then
      TLS_ENABLED=1
    fi
    ;;
  *) die "SBP_TLS 仅支持 auto、1 或 0。" ;;
esac
if [[ ${TLS_ENABLED} == 1 ]] && ! is_dns_name "${PUBLIC_HOST}"; then
  die "Let's Encrypt 自动证书需要域名，不能使用 IP 地址。"
fi

PANEL_PUBLIC_PORT=${SBP_PANEL_PORT:-18080}
PANEL_PUBLIC_PORT=$(prompt "面板公网端口" "${PANEL_PUBLIC_PORT}")
valid_port "${PANEL_PUBLIC_PORT}" || die "面板公网端口无效。"

if [[ ${TLS_ENABLED} == 1 ]]; then
  PANEL_PORT=${SBP_PANEL_BACKEND_PORT:-}
  if [[ -n ${PANEL_PORT} ]]; then
    valid_port "${PANEL_PORT}" || die "SBP_PANEL_BACKEND_PORT 无效。"
    port_in_use "${PANEL_PORT}" && die "面板内部端口 ${PANEL_PORT} 已被占用。"
  else
    for candidate in 18081 18082 18083 18084 18085 18086 18087 18088 18089; do
      if [[ ${candidate} != "${PANEL_PUBLIC_PORT}" ]] && ! port_in_use "${candidate}"; then
        PANEL_PORT=${candidate}
        break
      fi
    done
    [[ -n ${PANEL_PORT} ]] || die "18081–18089 均已占用，请用 SBP_PANEL_BACKEND_PORT 指定内部端口。"
  fi
else
  PANEL_PORT=${PANEL_PUBLIC_PORT}
  port_in_use "${PANEL_PORT}" && die "面板端口 ${PANEL_PORT} 已被占用。"
fi

VLESS_REQUESTED=${SBP_VLESS_PORT:-443}
VLESS_REQUESTED=$(prompt "VLESS Reality 公网端口" "${VLESS_REQUESTED}")
valid_port "${VLESS_REQUESTED}" || die "VLESS 端口无效。"
if port_in_use "${VLESS_REQUESTED}"; then
  if [[ -z ${SBP_VLESS_PORT:-} && ${VLESS_REQUESTED} == 443 ]] && ! port_in_use 34443; then
    warn "公网 443 已被占用，VLESS 自动改用 34443。"
    VLESS_PORT=34443
  else
    die "节点端口 ${VLESS_REQUESTED} 已被占用；安装器不会强行停止现有网站或代理。"
  fi
else
  VLESS_PORT=${VLESS_REQUESTED}
fi
[[ ${VLESS_PORT} != "${PANEL_PORT}" ]] || die "面板监听端口与 VLESS 端口不能相同。"

REALITY_SERVER=${SBP_REALITY_SERVER:-www.apple.com}
REALITY_SERVER=$(prompt "Reality 伪装/握手域名" "${REALITY_SERVER}")
[[ ${REALITY_SERVER} =~ ^[A-Za-z0-9.-]+$ ]] || die "SBP_REALITY_SERVER 无效。"
ADMIN_USER=${SBP_ADMIN_USER:-admin}
ADMIN_USER=$(prompt "管理员用户名" "${ADMIN_USER}")
[[ ${ADMIN_USER} =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "SBP_ADMIN_USER 无效。"
ADMIN_PASSWORD=${SBP_ADMIN_PASSWORD:-}
if [[ -z ${ADMIN_PASSWORD} ]]; then ADMIN_PASSWORD=$(prompt_secret "管理员密码"); fi
ADMIN_PASSWORD=${ADMIN_PASSWORD:-$(openssl rand -hex 16)}
(( ${#ADMIN_PASSWORD} >= 12 )) || die "SBP_ADMIN_PASSWORD 至少需要 12 个字符。"
[[ ${ADMIN_PASSWORD} =~ ^[A-Za-z0-9._~!@%^+=:-]+$ ]] || die "SBP_ADMIN_PASSWORD 含有不支持的字符。"
TLS_EMAIL=${SBP_TLS_EMAIL:-}
if [[ ${TLS_ENABLED} == 1 ]]; then TLS_EMAIL=$(prompt "Let's Encrypt 联系邮箱（可留空）" "${TLS_EMAIL}"); fi
[[ -z ${TLS_EMAIL} || ${TLS_EMAIL} =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "邮箱格式无效。"

if [[ ${TLS_ENABLED} == 1 ]]; then
  if [[ ${PANEL_PUBLIC_PORT} == 443 ]]; then EXPECTED_PUBLIC_URL="https://${PUBLIC_HOST}"; else EXPECTED_PUBLIC_URL="https://${PUBLIC_HOST}:${PANEL_PUBLIC_PORT}"; fi
else
  if [[ ${PANEL_PUBLIC_PORT} == 80 ]]; then EXPECTED_PUBLIC_URL="http://${PUBLIC_HOST}"; else EXPECTED_PUBLIC_URL="http://${PUBLIC_HOST}:${PANEL_PUBLIC_PORT}"; fi
fi
if [[ -n ${SBP_PUBLIC_BASE_URL:-} ]]; then
  PUBLIC_BASE_URL=${SBP_PUBLIC_BASE_URL}
else
  PUBLIC_BASE_URL=${EXPECTED_PUBLIC_URL}
fi
[[ ${PUBLIC_BASE_URL} =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die "SBP_PUBLIC_BASE_URL 仅支持 http(s)://主机:端口。"
if [[ ${TLS_ENABLED} == 1 && ${PUBLIC_BASE_URL} != "${EXPECTED_PUBLIC_URL}" ]]; then
  die "启用自动 HTTPS 时，SBP_PUBLIC_BASE_URL 必须为 ${EXPECTED_PUBLIC_URL}。"
fi

install_native_nginx() {
  port_in_use 80 && die "公网 80 已被未知服务占用，无法自动安装用于 HTTPS 的 Nginx。"
  log "未发现 OpenResty/Nginx，安装原生 Nginx"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nginx
  elif command -v yum >/dev/null 2>&1; then
    yum install -y nginx
  else
    die "无法自动安装 Nginx，请先安装 OpenResty 或 Nginx 后重试。"
  fi
  systemctl enable --now nginx >/dev/null
}

container_has_public_http() {
  local container=$1
  docker inspect "${container}" | jq -e '
    .[0] as $c |
    ($c.HostConfig.NetworkMode == "host") or
    any($c.NetworkSettings.Ports["80/tcp"][]?; .HostPort == "80")
  ' >/dev/null 2>&1
}

detect_container_web() {
  command -v docker >/dev/null 2>&1 || return 1
  local container network mount source destination gateway expanded base_source base_destination
  while IFS=$'\t' read -r container _; do
    [[ -n ${container} ]] || continue
    container_has_public_http "${container}" || continue
    if docker exec "${container}" openresty -t >/dev/null 2>&1; then
      WEB_BINARY=openresty
    elif docker exec "${container}" nginx -t >/dev/null 2>&1; then
      WEB_BINARY=nginx
    else
      continue
    fi
    mount=$(docker inspect "${container}" | jq -r '
      first(.[0].Mounts[] |
        select(.RW == true and (.Destination | endswith("/conf.d"))) |
        [.Source, .Destination] | @tsv) // empty
    ')
    if [[ -z ${mount} ]]; then
      expanded=$(docker exec "${container}" "${WEB_BINARY}" -T 2>&1)
      while IFS=$'\t' read -r base_source base_destination; do
        [[ -d ${base_source}/conf.d ]] || continue
        if grep -F "${base_destination}/conf.d/*.conf" <<<"${expanded}" >/dev/null; then
          mount=${base_source}/conf.d$'\t'${base_destination}/conf.d
          break
        fi
      done < <(docker inspect "${container}" | jq -r '.[0].Mounts[] | select(.RW == true) | [.Source, .Destination] | @tsv')
    fi
    [[ -n ${mount} ]] || continue
    IFS=$'\t' read -r source destination <<<"${mount}"
    [[ -d ${source} ]] || continue
    network=$(docker inspect "${container}" --format '{{.HostConfig.NetworkMode}}')
    if [[ ${network} == host ]]; then
      gateway=127.0.0.1
    else
      gateway=$(docker inspect "${container}" | jq -r '.[0].NetworkSettings.Networks | to_entries[0].value.Gateway // empty')
      [[ -n ${gateway} ]] || continue
    fi
    WEB_MODE=container
    WEB_CONTAINER=${container}
    WEB_CONF_HOST=${source}
    WEB_CONF_RUNTIME=${destination}
    WEB_PROXY_HOST=${gateway}
    return 0
  done < <(
    docker ps --format '{{.Names}}\t{{.Image}}' |
      awk '{line=tolower($0); if (line ~ /openresty|nginx/) {priority=(line ~ /1panel.*openresty/ ? 0 : 1); print priority "\t" $0}}' |
      sort -n | cut -f2-
  )
  return 1
}

detect_host_web() {
  local dump candidate binary service
  if command -v openresty >/dev/null 2>&1; then
    binary=$(command -v openresty)
    service=openresty
  elif [[ -x /usr/local/openresty/bin/openresty ]]; then
    binary=/usr/local/openresty/bin/openresty
    service=openresty
  elif command -v nginx >/dev/null 2>&1; then
    binary=$(command -v nginx)
    service=nginx
  else
    return 1
  fi
  dump=$(${binary} -T 2>&1) || return 1
  for candidate in /etc/nginx/conf.d /etc/openresty/conf.d /usr/local/openresty/nginx/conf/conf.d; do
    [[ -d ${candidate} ]] || continue
    if grep -F "${candidate}/*.conf" <<<"${dump}" >/dev/null; then
      WEB_MODE=host
      WEB_BINARY=${binary}
      WEB_SERVICE=${service}
      WEB_CONF_HOST=${candidate}
      WEB_CONF_RUNTIME=${candidate}
      WEB_PROXY_HOST=127.0.0.1
      if systemctl list-unit-files "${service}.service" --no-legend 2>/dev/null | grep -q .; then
        if ! systemctl is-active --quiet "${service}"; then
          port_in_use 80 && return 1
          systemctl enable --now "${service}" >/dev/null
        fi
      elif ! port_in_use 80; then
        "${binary}"
      fi
      return 0
    fi
  done
  return 1
}

detect_web_server() {
  if detect_container_web; then
    log "检测到容器版 ${WEB_BINARY}：${WEB_CONTAINER}"
    return
  fi
  if detect_host_web; then
    log "检测到宿主机原生 ${WEB_BINARY}"
    return
  fi
  if port_in_use 80; then
    die "公网 80 已被无法识别的服务占用；安装器不会停止未知服务。请释放 80 或使用 SBP_TLS=0。"
  fi
  install_native_nginx
  detect_host_web || die "Nginx 安装完成但无法找到可写且已 include 的 conf.d 目录。"
}

web_test() {
  if [[ ${WEB_MODE} == container ]]; then
    docker exec "${WEB_CONTAINER}" "${WEB_BINARY}" -t
  else
    "${WEB_BINARY}" -t
  fi
}

web_reload() {
  if [[ ${WEB_MODE} == container ]]; then
    docker exec "${WEB_CONTAINER}" "${WEB_BINARY}" -s reload
  elif systemctl list-unit-files "${WEB_SERVICE}.service" --no-legend 2>/dev/null | grep -q .; then
    systemctl reload "${WEB_SERVICE}"
  else
    "${WEB_BINARY}" -s reload
  fi
}

web_dump() {
  if [[ ${WEB_MODE} == container ]]; then
    docker exec "${WEB_CONTAINER}" "${WEB_BINARY}" -T 2>&1
  else
    "${WEB_BINARY}" -T 2>&1
  fi
}

rollback_web_config() {
  [[ -n ${WEB_CONFIG_FILE} ]] || return 0
  warn "恢复安装前的 Web 配置"
  if [[ -n ${WEB_CONFIG_BACKUP} && -f ${WEB_CONFIG_BACKUP} ]]; then
    cp -a "${WEB_CONFIG_BACKUP}" "${WEB_CONFIG_FILE}"
  else
    rm -f "${WEB_CONFIG_FILE}"
  fi
  if web_test >/dev/null 2>&1; then web_reload >/dev/null 2>&1 || true; fi
  TLS_ROLLBACK_PENDING=0
}

apply_web_config() {
  local source=$1
  install -o root -g root -m 0644 "${source}" "${WEB_CONFIG_FILE}"
  web_test || die "新的 OpenResty/Nginx 配置校验失败，正在自动恢复。"
  web_reload
}

write_reload_helper() {
  if [[ ${WEB_MODE} == container ]]; then
    cat >/usr/local/libexec/sb-panel-web-reload <<EOF
#!/usr/bin/env bash
set -euo pipefail
docker exec '${WEB_CONTAINER}' '${WEB_BINARY}' -t
docker exec '${WEB_CONTAINER}' '${WEB_BINARY}' -s reload
EOF
  else
    cat >/usr/local/libexec/sb-panel-web-reload <<EOF
#!/usr/bin/env bash
set -euo pipefail
'${WEB_BINARY}' -t
if systemctl list-unit-files '${WEB_SERVICE}.service' --no-legend 2>/dev/null | grep -q .; then
  systemctl reload '${WEB_SERVICE}'
else
  '${WEB_BINARY}' -s reload
fi
EOF
  fi
  chmod 0755 /usr/local/libexec/sb-panel-web-reload
}

prepare_tls() {
  [[ ${TLS_ENABLED} == 1 ]] || return 0
  [[ ${PANEL_PUBLIC_PORT} != "${VLESS_PORT}" ]] || die "面板 HTTPS 端口不能与 VLESS 端口相同。"
  detect_web_server

  local safe stamp resolved acme_source expanded
  safe=${PUBLIC_HOST//[^A-Za-z0-9.-]/_}
  WEB_CONFIG_FILE=${WEB_CONF_HOST}/zz-sb-panel-${safe}.conf
  expanded=$(web_dump)
  if grep -E "server_name[[:space:]]+([^;[:space:]]+[[:space:]]+)*${PUBLIC_HOST//./\\.}([[:space:];])" <<<"${expanded}" >/dev/null; then
    if [[ ! -f ${WEB_CONFIG_FILE} ]] || ! grep -F "Managed by SB Panel" "${WEB_CONFIG_FILE}" >/dev/null; then
      die "域名 ${PUBLIC_HOST} 已存在于当前 Web 配置中。为防止覆盖现有网站，请换一个面板子域名。"
    fi
  fi
  if port_in_use "${PANEL_PUBLIC_PORT}" && [[ ${PANEL_PUBLIC_PORT} != 80 ]]; then
    if grep -E "listen[[:space:]]+([^;[:space:]]+:)?${PANEL_PUBLIC_PORT}([[:space:];])" <<<"${expanded}" >/dev/null; then
      log "面板公网端口 ${PANEL_PUBLIC_PORT} 已由现有 Web 服务监听，将复用该监听器。"
    else
      die "面板公网端口 ${PANEL_PUBLIC_PORT} 被其他服务占用，请选择空闲端口。"
    fi
  fi

  stamp=$(date -u +%Y%m%d-%H%M%S)
  WEB_ROOT_HOST=${WEB_CONF_HOST}/sb-panel-acme/${safe}
  WEB_ROOT_RUNTIME=${WEB_CONF_RUNTIME}/sb-panel-acme/${safe}
  WEB_CERT_HOST=${WEB_CONF_HOST}/sb-panel-certs/${safe}
  WEB_CERT_RUNTIME=${WEB_CONF_RUNTIME}/sb-panel-certs/${safe}
  install -d -m 0755 "${WEB_ROOT_HOST}/.well-known/acme-challenge" "${WEB_CERT_HOST}"
  if [[ -f ${WEB_CONFIG_FILE} ]]; then
    install -d -m 0700 "${BACKUP_ROOT}/${stamp}-tls-config"
    WEB_CONFIG_BACKUP=${BACKUP_ROOT}/${stamp}-tls-config/$(basename "${WEB_CONFIG_FILE}")
    cp -a "${WEB_CONFIG_FILE}" "${WEB_CONFIG_BACKUP}"
  fi
  TLS_ROLLBACK_PENDING=1

  cat >"${TMP_DIR}/sb-panel-http.conf" <<EOF
# Managed by SB Panel. Manual changes may be replaced by the installer.
server {
    listen 80;
    server_name ${PUBLIC_HOST};

    location ^~ /.well-known/acme-challenge/ {
        root ${WEB_ROOT_RUNTIME};
        default_type text/plain;
        try_files \$uri =404;
    }

    location / { return 404; }
}
EOF
  apply_web_config "${TMP_DIR}/sb-panel-http.conf"

  printf 'sb-panel-acme-ok\n' >"${WEB_ROOT_HOST}/.well-known/acme-challenge/preflight"
  if [[ $(curl --noproxy '*' -fsS --max-time 5 --resolve "${PUBLIC_HOST}:80:127.0.0.1" "http://${PUBLIC_HOST}/.well-known/acme-challenge/preflight" 2>/dev/null || true) != sb-panel-acme-ok ]]; then
    die "本机 HTTP-01 预检失败：OpenResty/Nginx 未正确提供 ACME 验证目录。"
  fi
  rm -f "${WEB_ROOT_HOST}/.well-known/acme-challenge/preflight"

  if command -v getent >/dev/null 2>&1; then
    resolved=$({ getent ahostsv4 "${PUBLIC_HOST}" || true; } | awk '{print $1}' | sort -u | paste -sd, -)
    log "DNS 检查：${PUBLIC_HOST} -> ${resolved:-未解析}；本机公网 IP：${DETECTED_PUBLIC_IP:-未知}"
    [[ -n ${resolved} ]] || die "域名尚未解析，无法申请证书。"
    if [[ -n ${DETECTED_PUBLIC_IP} && ,${resolved}, != *",${DETECTED_PUBLIC_IP},"* ]]; then
      warn "域名未直接解析到本机公网 IP；若使用 Cloudflare 代理，请确认其能访问本机 80 端口。"
    fi
  fi

  log "安装固定版本 acme.sh ${ACME_SH_VERSION}"
  download "https://github.com/acmesh-official/acme.sh/archive/refs/tags/${ACME_SH_VERSION}.tar.gz" "${TMP_DIR}/acme.sh.tar.gz"
  tar -xzf "${TMP_DIR}/acme.sh.tar.gz" -C "${TMP_DIR}"
  acme_source=$(find "${TMP_DIR}" -maxdepth 2 -type f -path '*/acme.sh' -print -quit)
  [[ -n ${acme_source} ]] || die "acme.sh 发布包内容无效。"
  install -d -m 0700 "${APP_ROOT}/acme" "${CONFIG_DIR}/acme"
  (
    cd "$(dirname "${acme_source}")"
    if [[ -n ${TLS_EMAIL} ]]; then
      ./acme.sh --install --home "${APP_ROOT}/acme" --config-home "${CONFIG_DIR}/acme" --cert-home "${CONFIG_DIR}/acme/certs" --accountemail "${TLS_EMAIL}" --no-cron --no-profile
    else
      ./acme.sh --install --home "${APP_ROOT}/acme" --config-home "${CONFIG_DIR}/acme" --cert-home "${CONFIG_DIR}/acme/certs" --no-cron --no-profile
    fi
  )

  log "通过 Let's Encrypt HTTP-01 申请证书"
  "${APP_ROOT}/acme/acme.sh" --issue --server letsencrypt --home "${APP_ROOT}/acme" --config-home "${CONFIG_DIR}/acme" --cert-home "${CONFIG_DIR}/acme/certs" --keylength ec-256 -d "${PUBLIC_HOST}" -w "${WEB_ROOT_HOST}"
  write_reload_helper
  touch "${WEB_CERT_HOST}/privkey.pem" "${WEB_CERT_HOST}/fullchain.pem"
  chmod 0600 "${WEB_CERT_HOST}/privkey.pem"
  chmod 0644 "${WEB_CERT_HOST}/fullchain.pem"
  "${APP_ROOT}/acme/acme.sh" --install-cert --server letsencrypt --home "${APP_ROOT}/acme" --config-home "${CONFIG_DIR}/acme" --cert-home "${CONFIG_DIR}/acme/certs" --ecc -d "${PUBLIC_HOST}" --key-file "${WEB_CERT_HOST}/privkey.pem" --fullchain-file "${WEB_CERT_HOST}/fullchain.pem" --reloadcmd /usr/local/libexec/sb-panel-web-reload
}

finalize_tls() {
  [[ ${TLS_ENABLED} == 1 ]] || return 0
  local redirect_port=
  [[ ${PANEL_PUBLIC_PORT} != 443 ]] && redirect_port=:${PANEL_PUBLIC_PORT}
  cat >"${TMP_DIR}/sb-panel-https.conf" <<EOF
# Managed by SB Panel. Manual changes may be replaced by the installer.
server {
    listen 80;
    server_name ${PUBLIC_HOST};

    location ^~ /.well-known/acme-challenge/ {
        root ${WEB_ROOT_RUNTIME};
        default_type text/plain;
        try_files \$uri =404;
    }

    location / { return 308 https://\$host${redirect_port}\$request_uri; }
}

server {
    listen ${PANEL_PUBLIC_PORT} ssl;
    server_name ${PUBLIC_HOST};

    ssl_certificate ${WEB_CERT_RUNTIME}/fullchain.pem;
    ssl_certificate_key ${WEB_CERT_RUNTIME}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SBPanelTLS:10m;
    ssl_session_timeout 1d;
    add_header Strict-Transport-Security "max-age=31536000" always;

    location / {
        proxy_pass http://${WEB_PROXY_HOST}:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port ${PANEL_PUBLIC_PORT};
    }
}
EOF
  apply_web_config "${TMP_DIR}/sb-panel-https.conf"
  if ! curl --noproxy '*' -fsS --max-time 8 --resolve "${PUBLIC_HOST}:${PANEL_PUBLIC_PORT}:127.0.0.1" "${PUBLIC_BASE_URL}/healthz" >/dev/null; then
    die "HTTPS 反向代理健康检查失败，正在自动恢复 Web 配置。"
  fi

  cat >/etc/systemd/system/sb-panel-cert-renew.service <<EOF
[Unit]
Description=Renew SB Panel TLS certificate
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${APP_ROOT}/acme/acme.sh --cron --home ${APP_ROOT}/acme --config-home ${CONFIG_DIR}/acme --cert-home ${CONFIG_DIR}/acme/certs
PrivateTmp=true
NoNewPrivileges=true
EOF
  cat >/etc/systemd/system/sb-panel-cert-renew.timer <<'EOF'
[Unit]
Description=Daily SB Panel certificate renewal check

[Timer]
OnCalendar=*-*-* 03:17:00
RandomizedDelaySec=45m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now sb-panel-cert-renew.timer >/dev/null
  TLS_ROLLBACK_PENDING=0
}

log "安装 sing-box ${SING_BOX_VERSION}"
SING_BOX_ARCHIVE=sing-box-${SING_BOX_VERSION}-linux-${ARCH}.tar.gz
download "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${SING_BOX_ARCHIVE}" "${TMP_DIR}/${SING_BOX_ARCHIVE}"
tar -xzf "${TMP_DIR}/${SING_BOX_ARCHIVE}" -C "${TMP_DIR}"
SING_BOX_SOURCE=$(find "${TMP_DIR}" -type f -name sing-box -print -quit)
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

prepare_tls

if [[ ${TLS_ENABLED} == 1 ]]; then
  PANEL_BIND_HOST=${WEB_PROXY_HOST}
  PANEL_COOKIE_SECURE=true
else
  PANEL_BIND_HOST=0.0.0.0
  PANEL_COOKIE_SECURE=false
fi

umask 077
cat >"${ENV_FILE}" <<EOF
PANEL_DATA_DIR=${DATA_DIR}
PANEL_DB=${DATA_DIR}/panel.db
PANEL_LISTEN=${PANEL_BIND_HOST}:${PANEL_PORT}
PANEL_ADMIN_USER=${ADMIN_USER}
PANEL_ADMIN_PASSWORD=${ADMIN_PASSWORD}
PANEL_COOKIE_SECURE=${PANEL_COOKIE_SECURE}
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

finalize_tls

cat >${BACKUP_ROOT}/credentials.txt <<EOF
SB Panel URL: ${PUBLIC_BASE_URL}
Username: ${ADMIN_USER}
Password: ${ADMIN_PASSWORD}
VLESS port: ${VLESS_PORT}
TLS enabled: ${TLS_ENABLED}
Installed: $(date -u +%FT%TZ)
EOF
chmod 0600 ${BACKUP_ROOT}/credentials.txt

log "安装完成：$(${PANEL_BIN} version)"
printf '\n访问地址：%s\n管理员：%s\n初始密码：%s\nVLESS 端口：%s\n\n' "${PUBLIC_BASE_URL}" "${ADMIN_USER}" "${ADMIN_PASSWORD}" "${VLESS_PORT}"
if [[ ${TLS_ENABLED} == 1 ]]; then
  log "Let's Encrypt 证书已启用自动续期。"
else
  warn "当前使用 HTTP。公开使用前请配置 HTTPS，并在面板中启用两步验证。"
fi
log "凭证已保存到 ${BACKUP_ROOT}/credentials.txt（权限 600）"
