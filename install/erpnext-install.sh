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
LOG_FILE="/var/log/erpnext-install.log"

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
msg_error() { echo -e "${BFR} ${CROSS} ${RD}${1}${CL}"; echo "See ${LOG_FILE} for details."; exit 1; }
msg_step()  { echo -e "\n${BOLD}${BL}── ${1}${CL}"; }

# Wrapper: run apt silently, log everything, abort on failure
apt_get() {
  DEBIAN_FRONTEND=noninteractive apt-get "$@" \
    --no-install-recommends -y \
    -o Dpkg::Options::="--force-confnew" \
    >> "$LOG_FILE" 2>&1 || {
      echo -e "${BFR}${CROSS} ${RD}apt-get failed — check ${LOG_FILE}${CL}"
      tail -20 "$LOG_FILE"
      exit 1
    }
}

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

# ─── Locale (must run first — fixes all perl/locale warnings) ─────────────────
setup_locale() {
  msg_step "Locale"
  msg_info "Configuring en_US.UTF-8 locale"
  apt_get install locales
  # Uncomment en_US.UTF-8 in locale.gen
  sed -i 's/^# *\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
  locale-gen en_US.UTF-8 >> "$LOG_FILE" 2>&1
  update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 LANGUAGE=en_US.UTF-8 \
    >> "$LOG_FILE" 2>&1
  # Apply for this shell session immediately
  export LANG=en_US.UTF-8
  export LC_ALL=en_US.UTF-8
  export LANGUAGE=en_US.UTF-8
  msg_ok "Locale set to en_US.UTF-8"
}

# ─── System update ────────────────────────────────────────────────────────────
system_update() {
  msg_step "System Update"
  msg_info "Updating package lists"
  apt_get update
  msg_ok "Package lists updated"

  msg_info "Upgrading installed packages"
  apt_get upgrade
  msg_ok "Packages upgraded"
}

# ─── Base dependencies ────────────────────────────────────────────────────────
install_base_deps() {
  msg_step "Base Dependencies"
  msg_info "Installing base packages"
  apt_get install \
    git curl wget gnupg lsb-release ca-certificates \
    sudo cron supervisor \
    xvfb libfontconfig1 \
    wkhtmltopdf \
    build-essential \
    python3 python3-dev python3-venv python3-setuptools python3-pip \
    libssl-dev libffi-dev \
    default-libmysqlclient-dev pkg-config \
    redis-server \
    fonts-cantarell xfonts-75dpi xfonts-base \
    xfonts-encodings xfonts-utils
  msg_ok "Base packages installed"
}

# ─── Node.js ─────────────────────────────────────────────────────────────────
install_nodejs() {
  msg_step "Node.js ${NODE_MAJOR}"
  if command -v node &>/dev/null; then
    local ver
    ver=$(node -v | cut -d. -f1 | tr -d 'v')
    if [[ "$ver" -ge "$NODE_MAJOR" ]]; then
      msg_ok "Node.js $(node -v) already installed"
      return
    fi
  fi

  msg_info "Adding NodeSource repository"
  mkdir -p /etc/apt/keyrings
  curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg 2>>"$LOG_FILE"
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] \
https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt_get update
  msg_ok "NodeSource repository added"

  msg_info "Installing Node.js ${NODE_MAJOR}"
  apt_get install nodejs
  msg_ok "Node.js $(node -v) installed"

  msg_info "Installing Yarn"
  npm install -g yarn >> "$LOG_FILE" 2>&1
  msg_ok "Yarn $(yarn --version) installed"
}

# ─── MariaDB ──────────────────────────────────────────────────────────────────
install_mariadb() {
  msg_step "MariaDB"
  if command -v mariadbd &>/dev/null || command -v mysqld &>/dev/null; then
    msg_ok "MariaDB already installed"
    return
  fi

  msg_info "Adding MariaDB 10.11 repository"
  curl -fsSL "https://downloads.mariadb.com/MariaDB/mariadb_repo_setup" \
    | bash -s -- --mariadb-server-version="mariadb-10.11" --skip-maxscale \
    >> "$LOG_FILE" 2>&1
  apt_get update
  msg_ok "MariaDB repository added"

  msg_info "Installing MariaDB server"
  apt_get install mariadb-server mariadb-client
  msg_ok "MariaDB installed"

  msg_info "Starting MariaDB"
  systemctl enable --now mariadb >> "$LOG_FILE" 2>&1
  # Wait for socket to appear
  local i=0
  while [[ ! -S /run/mysqld/mysqld.sock ]] && (( i < 20 )); do
    sleep 1; (( i++ ))
  done
  msg_ok "MariaDB started"

  msg_info "Securing MariaDB"
  mysql -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

  # Frappe-required settings
  cat > /etc/mysql/mariadb.conf.d/99-frappe.cnf <<'MYCNF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server            = utf8mb4
collation-server                = utf8mb4_unicode_ci
innodb_read_only_compressed     = OFF

[mysql]
default-character-set = utf8mb4
MYCNF

  systemctl restart mariadb >> "$LOG_FILE" 2>&1
  msg_ok "MariaDB configured"
}

# ─── Redis ────────────────────────────────────────────────────────────────────
configure_redis() {
  msg_step "Redis"
  msg_info "Enabling Redis"
  systemctl enable --now redis-server >> "$LOG_FILE" 2>&1
  msg_ok "Redis running"
}

# ─── Frappe Bench CLI ─────────────────────────────────────────────────────────
install_bench_cli() {
  msg_step "Frappe Bench CLI"
  if command -v bench &>/dev/null; then
    msg_ok "bench already installed"
    return
  fi

  msg_info "Installing bench (pip3 --break-system-packages)"
  # Debian 12 uses PEP 668 — --break-system-packages is required for system-wide install
  pip3 install --quiet --break-system-packages frappe-bench >> "$LOG_FILE" 2>&1
  msg_ok "bench $(bench --version 2>/dev/null | head -1) installed"
}

# ─── Frappe system user ───────────────────────────────────────────────────────
create_frappe_user() {
  msg_step "Frappe System User"
  if id "$BENCH_USER" &>/dev/null; then
    msg_ok "User '${BENCH_USER}' already exists"
  else
    msg_info "Creating user '${BENCH_USER}'"
    useradd -m -s /bin/bash "$BENCH_USER"
    msg_ok "User '${BENCH_USER}' created"
  fi

  # Scoped sudo rules required by bench
  cat > /etc/sudoers.d/frappe <<SUDOERS
${BENCH_USER} ALL=(ALL) NOPASSWD: /usr/sbin/service, /usr/bin/systemctl, /usr/local/bin/bench
SUDOERS
  chmod 0440 /etc/sudoers.d/frappe
  msg_ok "sudo rules written for '${BENCH_USER}'"
}

# ─── Bench init ───────────────────────────────────────────────────────────────
init_bench() {
  msg_step "Frappe Bench Init"

  if [[ -d "$BENCH_DIR" ]]; then
    msg_ok "Bench already at ${BENCH_DIR}"
    return
  fi

  msg_info "Initialising bench — branch ${FRAPPE_BRANCH} (takes a few minutes)"
  sudo -u "$BENCH_USER" bash -c "
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    bench init \
      --frappe-branch '${FRAPPE_BRANCH}' \
      --python '${PYTHON_VERSION}' \
      --skip-redis-config-generation \
      '${BENCH_DIR}'
  " >> "$LOG_FILE" 2>&1 || msg_error "bench init failed"
  msg_ok "Bench initialised at ${BENCH_DIR}"
}

# ─── ERPNext app ──────────────────────────────────────────────────────────────
get_erpnext_app() {
  msg_step "ERPNext App"
  if [[ -d "${BENCH_DIR}/apps/erpnext" ]]; then
    msg_ok "ERPNext already present"
    return
  fi

  msg_info "Fetching ERPNext — branch ${ERPNEXT_BRANCH}"
  sudo -u "$BENCH_USER" bash -c "
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    cd '${BENCH_DIR}'
    bench get-app erpnext --branch '${ERPNEXT_BRANCH}'
  " >> "$LOG_FILE" 2>&1 || msg_error "get-app erpnext failed"
  msg_ok "ERPNext app fetched"
}

# ─── HRMS app (optional) ──────────────────────────────────────────────────────
get_hrms_app() {
  [[ "${INSTALL_HRMS,,}" != "yes" ]] && return

  msg_step "HRMS App"
  if [[ -d "${BENCH_DIR}/apps/hrms" ]]; then
    msg_ok "HRMS already present"
    return
  fi

  msg_info "Fetching HRMS — branch ${FRAPPE_BRANCH}"
  sudo -u "$BENCH_USER" bash -c "
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    cd '${BENCH_DIR}'
    bench get-app hrms --branch '${FRAPPE_BRANCH}'
  " >> "$LOG_FILE" 2>&1 || msg_error "get-app hrms failed"
  msg_ok "HRMS app fetched"
}

# ─── Bench config ─────────────────────────────────────────────────────────────
configure_bench() {
  msg_step "Bench Configuration"
  msg_info "Writing Redis and port config"
  sudo -u "$BENCH_USER" bash -c "
    cd '${BENCH_DIR}'
    bench set-config -g redis_cache    'redis://127.0.0.1:6379/0'
    bench set-config -g redis_queue    'redis://127.0.0.1:6379/1'
    bench set-config -g redis_socketio 'redis://127.0.0.1:6379/2'
    bench set-config -g webserver_port 80
  " >> "$LOG_FILE" 2>&1
  msg_ok "Bench config written"
}

# ─── Create site ──────────────────────────────────────────────────────────────
create_site() {
  msg_step "Frappe Site: ${SITE_NAME}"
  if [[ -d "${BENCH_DIR}/sites/${SITE_NAME}" ]]; then
    msg_ok "Site '${SITE_NAME}' already exists"
    return
  fi

  msg_info "Creating site (takes several minutes)"
  sudo -u "$BENCH_USER" bash -c "
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    cd '${BENCH_DIR}'
    bench new-site '${SITE_NAME}' \
      --db-root-password '${DB_ROOT_PASSWORD}' \
      --admin-password   '${ADMIN_PASSWORD}'   \
      --no-mariadb-socket
  " >> "$LOG_FILE" 2>&1 || msg_error "bench new-site failed"
  msg_ok "Site '${SITE_NAME}' created"
}

# ─── Install apps on site ─────────────────────────────────────────────────────
install_apps_on_site() {
  msg_step "Installing Apps on Site"

  msg_info "Installing ERPNext on ${SITE_NAME}"
  sudo -u "$BENCH_USER" bash -c "
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    cd '${BENCH_DIR}'
    bench --site '${SITE_NAME}' install-app erpnext
  " >> "$LOG_FILE" 2>&1 || msg_error "install-app erpnext failed"
  msg_ok "ERPNext installed on site"

  if [[ "${INSTALL_HRMS,,}" == "yes" ]]; then
    msg_info "Installing HRMS on ${SITE_NAME}"
    sudo -u "$BENCH_USER" bash -c "
      export LANG=en_US.UTF-8
      export LC_ALL=en_US.UTF-8
      cd '${BENCH_DIR}'
      bench --site '${SITE_NAME}' install-app hrms
    " >> "$LOG_FILE" 2>&1 || msg_error "install-app hrms failed"
    msg_ok "HRMS installed on site"
  fi
}

# ─── Production (nginx + supervisor) ─────────────────────────────────────────
setup_production() {
  msg_step "Production Setup"

  msg_info "Installing nginx"
  apt_get install nginx
  msg_ok "nginx installed"

  msg_info "Generating supervisor / nginx config"
  sudo -u "$BENCH_USER" bash -c "
    cd '${BENCH_DIR}'
    bench setup supervisor --yes
    bench setup nginx      --yes
  " >> "$LOG_FILE" 2>&1 || msg_error "bench setup production failed"

  cp -f "${BENCH_DIR}/config/supervisor.conf" /etc/supervisor/conf.d/frappe-bench.conf
  cp -f "${BENCH_DIR}/config/nginx.conf"      /etc/nginx/conf.d/frappe-bench.conf
  rm -f /etc/nginx/sites-enabled/default

  systemctl enable supervisor nginx >> "$LOG_FILE" 2>&1
  supervisorctl reread  >> "$LOG_FILE" 2>&1
  supervisorctl update  >> "$LOG_FILE" 2>&1
  systemctl reload nginx >> "$LOG_FILE" 2>&1
  msg_ok "nginx + supervisor configured and started"
}

# ─── Scheduler ────────────────────────────────────────────────────────────────
enable_scheduler() {
  msg_step "Scheduler"
  msg_info "Enabling scheduler on ${SITE_NAME}"
  sudo -u "$BENCH_USER" bash -c "
    cd '${BENCH_DIR}'
    bench --site '${SITE_NAME}' enable-scheduler
  " >> "$LOG_FILE" 2>&1
  msg_ok "Scheduler enabled"
}

# ─── fail2ban ─────────────────────────────────────────────────────────────────
configure_fail2ban() {
  msg_step "fail2ban"
  msg_info "Installing fail2ban"
  apt_get install fail2ban
  systemctl enable --now fail2ban >> "$LOG_FILE" 2>&1
  msg_ok "fail2ban installed and running"
}

# ─── Save credentials ─────────────────────────────────────────────────────────
save_credentials() {
  local cred_file="/root/erpnext-credentials.txt"
  cat > "$cred_file" <<CREDS
ERPNext Installation Credentials
=================================
Site Name      : ${SITE_NAME}
Admin Password : ${ADMIN_PASSWORD}
DB Root Pw     : ${DB_ROOT_PASSWORD}

Access the UI at : http://<container-ip>
Login            : Administrator
Password         : ${ADMIN_PASSWORD}

Install log      : ${LOG_FILE}
Generated        : $(date -u)
CREDS
  chmod 600 "$cred_file"
  msg_ok "Credentials saved to ${cred_file}"
}

print_done() {
  echo
  echo -e "${BOLD}${GN}═══════════════════════════════════════════════════${CL}"
  echo -e "${BOLD}${GN}  ERPNext Installation Finished Successfully!${CL}"
  echo -e "${BOLD}${GN}═══════════════════════════════════════════════════${CL}"
  echo -e " ${CM} Site        : ${BOLD}${SITE_NAME}${CL}"
  echo -e " ${CM} Login       : ${BOLD}Administrator${CL}"
  echo -e " ${CM} Password    : ${BOLD}${ADMIN_PASSWORD}${CL}"
  echo -e " ${CM} Credentials : ${BOLD}/root/erpnext-credentials.txt${CL}"
  echo -e " ${CM} Install log : ${BOLD}${LOG_FILE}${CL}"
  echo -e " ${CM} Branch      : ${BOLD}${FRAPPE_BRANCH}${CL}"
  echo -e " ${CM} HRMS        : ${BOLD}${INSTALL_HRMS}${CL}"
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

  # Initialise log file
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "ERPNext install started $(date -u)" > "$LOG_FILE"

  echo -e "\n${BOLD}${BL}ERPNext LXC — Container Installation${CL}\n"
  echo -e " Branch : ${FRAPPE_BRANCH}"
  echo -e " Site   : ${SITE_NAME}"
  echo -e " HRMS   : ${INSTALL_HRMS}"
  echo -e " Log    : ${LOG_FILE}\n"

  setup_locale        # ← must be first to silence all locale warnings
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
