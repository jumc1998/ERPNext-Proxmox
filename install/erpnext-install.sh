#!/usr/bin/env bash

# ERPNext LXC — Container-side Install Script
# Runs inside the Debian 12 LXC created by ct/erpnext.sh
# License: MIT

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
FRAPPE_BRANCH="version-15"
ERPNEXT_BRANCH="version-15"
SITE_NAME="site1.local"
INSTALL_HRMS="no"
BENCH_USER="frappe"
BENCH_DIR="/home/${BENCH_USER}/frappe-bench"
DB_ROOT_PASSWORD="$(openssl rand -base64 24)"
ADMIN_PASSWORD="$(openssl rand -base64 16)"

# Node / Python versions
NODE_MAJOR="20"
PYTHON_VERSION="python3"

# ─── Colour helpers ───────────────────────────────────────────────────────────
YW=$'\033[33m'
GN=$'\033[1;92m'
RD=$'\033[01;31m'
BL=$'\033[36m'
CL=$'\033[m'
BOLD=$'\033[1m'
BFR=$'\r\033[K'
HOLD=' '
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

msg_info()  { echo -ne " ${HOLD} ${YW}${1}...${CL}"; }
msg_ok()    { echo -e "${BFR} ${CM} ${GN}${1}${CL}"; }
msg_error() { echo -e "${BFR} ${CROSS} ${RD}${1}${CL}"; exit 1; }
msg_step()  { echo -e "\n${BOLD}${BL}── ${1}${CL}"; }

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --frappe-branch)   FRAPPE_BRANCH="$2";  shift 2 ;;
      --erpnext-branch)  ERPNEXT_BRANCH="$2"; shift 2 ;;
      --site-name)       SITE_NAME="$2";       shift 2 ;;
      --install-hrms)    INSTALL_HRMS="$2";    shift 2 ;;
      --admin-password)  ADMIN_PASSWORD="$2";  shift 2 ;;
      *) echo "Unknown argument: $1"; exit 1 ;;
    esac
  done
}

# ─── System preparation ───────────────────────────────────────────────────────
system_update() {
  msg_step "System Update"
  msg_info "Updating package lists"
  apt-get update -qq
  msg_ok "Package lists updated"

  msg_info "Upgrading installed packages"
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
  msg_ok "Packages upgraded"
}

install_base_deps() {
  msg_step "Base Dependencies"
  msg_info "Installing base packages"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    git curl wget sudo gnupg lsb-release ca-certificates \
    xvfb libfontconfig wkhtmltopdf \
    cron supervisor \
    build-essential \
    python3 python3-pip python3-dev python3-venv python3-setuptools \
    libssl-dev libffi-dev \
    default-libmysqlclient-dev pkg-config \
    redis-server \
    fonts-cantarell \
    xfonts-75dpi xfonts-base
  msg_ok "Base packages installed"
}

install_nodejs() {
  msg_step "Node.js ${NODE_MAJOR}"
  if command -v node &>/dev/null && [[ "$(node -v | cut -d. -f1 | tr -d 'v')" -ge "$NODE_MAJOR" ]]; then
    msg_ok "Node.js $(node -v) already installed"
    return
  fi

  msg_info "Adding NodeSource repository"
  curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] \
    https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
  msg_ok "Node.js $(node -v) installed"

  msg_info "Installing Yarn"
  npm install -g yarn --quiet
  msg_ok "Yarn $(yarn --version) installed"
}

install_mariadb() {
  msg_step "MariaDB"
  if command -v mysqld &>/dev/null; then
    msg_ok "MariaDB already installed"
    return
  fi

  msg_info "Adding MariaDB repository"
  curl -fsSL "https://downloads.mariadb.com/MariaDB/mariadb_repo_setup" \
    | bash -s -- --mariadb-server-version="mariadb-10.11" --skip-maxscale &>/dev/null
  apt-get update -qq
  msg_ok "MariaDB repository added"

  msg_info "Installing MariaDB server"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    mariadb-server mariadb-client
  msg_ok "MariaDB installed"

  msg_info "Configuring MariaDB"
  systemctl enable --now mariadb &>/dev/null

  # Secure installation (non-interactive)
  mysql -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

  # Frappe-required MariaDB settings
  cat > /etc/mysql/mariadb.conf.d/99-frappe.cnf <<'MYCNF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server            = utf8mb4
collation-server                = utf8mb4_unicode_ci
innodb_read_only_compressed     = OFF

[mysql]
default-character-set = utf8mb4
MYCNF

  systemctl restart mariadb
  msg_ok "MariaDB configured"
}

configure_redis() {
  msg_step "Redis"
  msg_info "Enabling Redis service"
  systemctl enable --now redis-server &>/dev/null
  msg_ok "Redis running"
}

install_bench_cli() {
  msg_step "Frappe Bench CLI"
  if command -v bench &>/dev/null; then
    msg_ok "bench already installed ($(bench --version 2>/dev/null || echo 'unknown version'))"
    return
  fi

  msg_info "Installing bench via pip"
  pip3 install --quiet frappe-bench
  msg_ok "bench CLI installed"
}

create_frappe_user() {
  msg_step "Frappe System User"
  if id "$BENCH_USER" &>/dev/null; then
    msg_ok "User '${BENCH_USER}' already exists"
  else
    msg_info "Creating user '${BENCH_USER}'"
    useradd -m -s /bin/bash "$BENCH_USER"
    msg_ok "User '${BENCH_USER}' created"
  fi

  # Allow frappe user to run specific commands via sudo (needed by bench)
  cat > /etc/sudoers.d/frappe <<SUDOERS
${BENCH_USER} ALL=(ALL) NOPASSWD: /usr/sbin/service, /usr/bin/systemctl, /usr/local/bin/bench
SUDOERS
  chmod 0440 /etc/sudoers.d/frappe
  msg_ok "sudo rules set for '${BENCH_USER}'"
}

init_bench() {
  msg_step "Frappe Bench Initialisation"

  if [[ -d "$BENCH_DIR" ]]; then
    msg_ok "Bench directory already exists at ${BENCH_DIR}"
    return
  fi

  msg_info "Initialising bench (branch: ${FRAPPE_BRANCH}) — this may take a few minutes"
  sudo -u "$BENCH_USER" bash -c "
    bench init \
      --frappe-branch '${FRAPPE_BRANCH}' \
      --python '${PYTHON_VERSION}' \
      --skip-redis-config-generation \
      '${BENCH_DIR}'
  "
  msg_ok "Bench initialised at ${BENCH_DIR}"
}

get_erpnext_app() {
  msg_step "ERPNext Application"
  local installed
  installed=$(sudo -u "$BENCH_USER" bash -c \
    "cd '${BENCH_DIR}' && bench find-project erpnext 2>/dev/null || true")
  if [[ -n "$installed" ]]; then
    msg_ok "ERPNext already downloaded"
    return
  fi

  msg_info "Fetching ERPNext app (branch: ${ERPNEXT_BRANCH})"
  sudo -u "$BENCH_USER" bash -c "
    cd '${BENCH_DIR}'
    bench get-app erpnext \
      --branch '${ERPNEXT_BRANCH}'
  "
  msg_ok "ERPNext app fetched"
}

get_hrms_app() {
  if [[ "${INSTALL_HRMS,,}" != "yes" ]]; then return; fi

  msg_step "HRMS Application"
  msg_info "Fetching HRMS app"
  sudo -u "$BENCH_USER" bash -c "
    cd '${BENCH_DIR}'
    bench get-app hrms \
      --branch '${FRAPPE_BRANCH}'
  " && msg_ok "HRMS app fetched"
}

configure_bench() {
  msg_step "Bench Configuration"
  msg_info "Writing Redis / socket configuration"

  sudo -u "$BENCH_USER" bash -c "
    cd '${BENCH_DIR}'
    bench set-config -g redis_cache   'redis://127.0.0.1:6379/0'
    bench set-config -g redis_queue   'redis://127.0.0.1:6379/1'
    bench set-config -g redis_socketio 'redis://127.0.0.1:6379/2'
    bench set-config -g webserver_port 80
  "
  msg_ok "Bench configuration written"
}

create_site() {
  msg_step "Frappe Site: ${SITE_NAME}"

  local existing
  existing=$(sudo -u "$BENCH_USER" bash -c \
    "ls '${BENCH_DIR}/sites/' 2>/dev/null | grep '^${SITE_NAME}$' || true")
  if [[ -n "$existing" ]]; then
    msg_ok "Site '${SITE_NAME}' already exists"
    return
  fi

  msg_info "Creating site '${SITE_NAME}' (this may take several minutes)"
  sudo -u "$BENCH_USER" bash -c "
    cd '${BENCH_DIR}'
    bench new-site '${SITE_NAME}' \
      --db-root-password '${DB_ROOT_PASSWORD}' \
      --admin-password   '${ADMIN_PASSWORD}'   \
      --no-mariadb-socket
  "
  msg_ok "Site '${SITE_NAME}' created"
}

install_apps_on_site() {
  msg_step "Installing Apps on Site"

  msg_info "Installing ERPNext on ${SITE_NAME}"
  sudo -u "$BENCH_USER" bash -c "
    cd '${BENCH_DIR}'
    bench --site '${SITE_NAME}' install-app erpnext
  "
  msg_ok "ERPNext installed on site"

  if [[ "${INSTALL_HRMS,,}" == "yes" ]]; then
    msg_info "Installing HRMS on ${SITE_NAME}"
    sudo -u "$BENCH_USER" bash -c "
      cd '${BENCH_DIR}'
      bench --site '${SITE_NAME}' install-app hrms
    "
    msg_ok "HRMS installed on site"
  fi
}

setup_production() {
  msg_step "Production Setup (nginx + supervisor)"

  msg_info "Installing nginx"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx
  msg_ok "nginx installed"

  msg_info "Configuring supervisor and nginx for Frappe"
  sudo -u "$BENCH_USER" bash -c "
    cd '${BENCH_DIR}'
    bench setup supervisor --yes
    bench setup nginx     --yes
  "

  cp -f "${BENCH_DIR}/config/supervisor.conf" /etc/supervisor/conf.d/frappe-bench.conf
  cp -f "${BENCH_DIR}/config/nginx.conf"      /etc/nginx/conf.d/frappe-bench.conf
  rm -f /etc/nginx/sites-enabled/default

  systemctl enable supervisor nginx &>/dev/null
  supervisorctl reread   &>/dev/null
  supervisorctl update   &>/dev/null
  systemctl reload nginx &>/dev/null

  msg_ok "Production services configured"
}

enable_scheduler() {
  msg_step "Scheduler"
  msg_info "Enabling bench scheduler"
  sudo -u "$BENCH_USER" bash -c "
    cd '${BENCH_DIR}'
    bench --site '${SITE_NAME}' enable-scheduler
  "
  msg_ok "Scheduler enabled"
}

configure_fail2ban() {
  msg_info "Installing fail2ban"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban &>/dev/null
  systemctl enable --now fail2ban &>/dev/null
  msg_ok "fail2ban installed and running"
}

save_credentials() {
  local cred_file="/root/erpnext-credentials.txt"
  cat > "$cred_file" <<CREDS
ERPNext Installation Credentials
=================================
Site Name      : ${SITE_NAME}
Admin Password : ${ADMIN_PASSWORD}
DB Root Pw     : ${DB_ROOT_PASSWORD}

Access the UI at: http://<container-ip>
Login            : Administrator
Password         : ${ADMIN_PASSWORD}

Generated: $(date -u)
CREDS
  chmod 600 "$cred_file"
  msg_ok "Credentials saved to ${cred_file}"
}

print_done() {
  echo
  echo -e "${BOLD}${GN}═══════════════════════════════════════════════════${CL}"
  echo -e "${BOLD}${GN}  ERPNext Installation Finished Successfully!${CL}"
  echo -e "${BOLD}${GN}═══════════════════════════════════════════════════${CL}"
  echo -e " ${CM} Site         : ${BOLD}${SITE_NAME}${CL}"
  echo -e " ${CM} Admin user   : ${BOLD}Administrator${CL}"
  echo -e " ${CM} Admin pass   : ${BOLD}${ADMIN_PASSWORD}${CL}"
  echo -e " ${CM} Credentials  : ${BOLD}/root/erpnext-credentials.txt${CL}"
  echo -e " ${CM} Branch       : ${BOLD}${FRAPPE_BRANCH}${CL}"
  echo -e " ${CM} HRMS         : ${BOLD}${INSTALL_HRMS}${CL}"
  echo -e "${BOLD}${GN}═══════════════════════════════════════════════════${CL}"
  echo
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root inside the container."
    exit 1
  fi

  parse_args "$@"

  echo -e "\n${BOLD}${BL}ERPNext LXC — Container Installation${CL}\n"
  echo -e " Branch : ${FRAPPE_BRANCH}"
  echo -e " Site   : ${SITE_NAME}"
  echo -e " HRMS   : ${INSTALL_HRMS}\n"

  system_update
  install_base_deps
  install_nodejs
  install_mariadb
  configure_redis
  install_bench_cli
  create_frappe_user
  init_bench
  get_erpnext_app
  get_hrms_app
  configure_bench
  create_site
  install_apps_on_site
  setup_production
  enable_scheduler
  configure_fail2ban
  save_credentials
  print_done
}

main "$@"
