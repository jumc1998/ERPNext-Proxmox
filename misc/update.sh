#!/usr/bin/env bash

# ERPNext LXC — Update Script
# Run this inside the container to update Frappe/ERPNext to the latest patch.
# Usage: sudo bash /path/to/update.sh [--site site1.local]

set -euo pipefail

BENCH_USER="frappe"
BENCH_DIR="/home/${BENCH_USER}/frappe-bench"
SITE_NAME="site1.local"

GN=$'\033[1;92m'; RD=$'\033[01;31m'; YW=$'\033[33m'; CL=$'\033[m'; BOLD=$'\033[1m'
BFR=$'\r\033[K'; HOLD=' '
CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"
msg_info() { echo -ne " ${HOLD} ${YW}${1}...${CL}"; }
msg_ok()   { echo -e "${BFR} ${CM} ${GN}${1}${CL}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --site) SITE_NAME="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

echo -e "\n${BOLD}${GN}ERPNext Update — site: ${SITE_NAME}${CL}\n"

msg_info "Pulling latest changes"
sudo -u "$BENCH_USER" bash -c "cd '${BENCH_DIR}' && bench update --pull" 2>&1 | tail -5
msg_ok "Pulled latest changes"

msg_info "Running migrations"
sudo -u "$BENCH_USER" bash -c "
  cd '${BENCH_DIR}'
  bench --site '${SITE_NAME}' migrate
"
msg_ok "Migrations complete"

msg_info "Building assets"
sudo -u "$BENCH_USER" bash -c "cd '${BENCH_DIR}' && bench build --production"
msg_ok "Assets built"

msg_info "Restarting services"
supervisorctl restart all &>/dev/null
msg_ok "Services restarted"

echo -e "\n${BOLD}${GN}Update complete!${CL}\n"
