#!/usr/bin/env bash

# ERPNext LXC - Proxmox VE Helper Script
# Author: ERPNext-Proxmox Project
# License: MIT
#
# Usage: bash -c "$(wget -qO - https://raw.githubusercontent.com/jumc1998/ERPNext-Proxmox/main/ct/erpnext.sh)"

set -euo pipefail

# ─── Colour helpers ──────────────────────────────────────────────────────────
YW=$'\033[33m'
BL=$'\033[36m'
RD=$'\033[01;31m'
GN=$'\033[1;92m'
CL=$'\033[m'
BOLD=$'\033[1m'
BFR=$'\r\033[K'
HOLD=" "
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"
INFO="${BL}ℹ${CL}"

# ─── Script metadata ─────────────────────────────────────────────────────────
APP="ERPNext"
var_disk="40"
var_cpu="4"
var_ram="6144"
var_os="debian"
var_version="12"
var_unprivileged="1"

# ─── Defaults (can be overridden interactively) ───────────────────────────────
PCT_OSTYPE="$var_os"
PCT_OSVERSION="$var_version"
PCT_DISK_SIZE="$var_disk"
PCT_CPU="$var_cpu"
PCT_RAM="$var_ram"
PCT_UNPRIVILEGED="$var_unprivileged"
PCT_HOSTNAME="erpnext"
PCT_BRIDGE="vmbr0"
PCT_NET="dhcp"
PCT_VLAN=""
PCT_PASSWORD=""
INSTALL_FRAPPE_BRANCH="version-15"
INSTALL_ERPNEXT_BRANCH="version-15"
INSTALL_HRMS="no"

# ─── Helper functions ─────────────────────────────────────────────────────────

msg_info()  { echo -ne " ${HOLD} ${YW}${1}...${CL}"; }
msg_ok()    { echo -e "${BFR} ${CM} ${GN}${1}${CL}"; }
msg_error() { echo -e "${BFR} ${CROSS} ${RD}${1}${CL}"; }
msg_info2() { echo -e " ${INFO} ${BL}${1}${CL}"; }

check_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "This script must be run as root on your Proxmox VE host."
    exit 1
  fi
}

check_proxmox() {
  if ! command -v pvesh &>/dev/null; then
    msg_error "This script must be run on a Proxmox VE host."
    exit 1
  fi
  PVE_VERSION=$(pveversion | grep -oP '(?<=pve-manager/)\d+\.\d+')
  if (( $(echo "$PVE_VERSION < 7.0" | bc -l) )); then
    msg_error "Proxmox VE 7.0 or newer is required (found $PVE_VERSION)."
    exit 1
  fi
}

get_next_vmid() {
  pvesh get /cluster/nextid
}

get_storage_list() {
  pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1}' | head -1
}

validate_ip() {
  local ip="$1"
  [[ "$ip" == "dhcp" ]] && return 0
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]
}

# ─── Interactive configuration ────────────────────────────────────────────────

configure_interactively() {
  echo -e "\n${BOLD}${BL}ERPNext LXC — Configuration${CL}\n"

  # CT ID
  NEXTID=$(get_next_vmid)
  read -rp " ${YW}Container ID${CL} [${NEXTID}]: " input
  PCT_ID="${input:-$NEXTID}"

  # Hostname
  read -rp " ${YW}Hostname${CL} [${PCT_HOSTNAME}]: " input
  PCT_HOSTNAME="${input:-$PCT_HOSTNAME}"

  # Password
  while true; do
    read -rsp " ${YW}Root password${CL} (leave blank for SSH-key-only): " input
    echo
    PCT_PASSWORD="$input"
    if [[ -z "$PCT_PASSWORD" ]]; then break; fi
    read -rsp " ${YW}Confirm password${CL}: " confirm
    echo
    [[ "$PCT_PASSWORD" == "$confirm" ]] && break
    msg_error "Passwords do not match, try again."
  done

  # CPU
  read -rp " ${YW}CPU cores${CL} [${PCT_CPU}]: " input
  PCT_CPU="${input:-$PCT_CPU}"

  # RAM
  read -rp " ${YW}RAM (MiB)${CL} [${PCT_RAM}]: " input
  PCT_RAM="${input:-$PCT_RAM}"

  # Disk
  read -rp " ${YW}Disk size (GiB)${CL} [${PCT_DISK_SIZE}]: " input
  PCT_DISK_SIZE="${input:-$PCT_DISK_SIZE}"

  # Storage
  DEFAULT_STORAGE=$(get_storage_list)
  read -rp " ${YW}Storage pool${CL} [${DEFAULT_STORAGE}]: " input
  PCT_STORAGE="${input:-$DEFAULT_STORAGE}"

  # Bridge
  read -rp " ${YW}Network bridge${CL} [${PCT_BRIDGE}]: " input
  PCT_BRIDGE="${input:-$PCT_BRIDGE}"

  # IP
  read -rp " ${YW}IP address (CIDR or 'dhcp')${CL} [dhcp]: " input
  PCT_NET="${input:-dhcp}"
  if ! validate_ip "$PCT_NET"; then
    msg_error "Invalid IP format. Use x.x.x.x/prefix or 'dhcp'."
    exit 1
  fi

  # Gateway (only needed for static)
  if [[ "$PCT_NET" != "dhcp" ]]; then
    read -rp " ${YW}Gateway${CL}: " PCT_GW
  fi

  # VLAN
  read -rp " ${YW}VLAN tag${CL} (blank for none): " PCT_VLAN

  # Frappe/ERPNext version
  echo -e "\n ${YW}Available versions:${CL} version-14  version-15"
  read -rp " ${YW}Frappe/ERPNext branch${CL} [${INSTALL_FRAPPE_BRANCH}]: " input
  INSTALL_FRAPPE_BRANCH="${input:-$INSTALL_FRAPPE_BRANCH}"
  INSTALL_ERPNEXT_BRANCH="$INSTALL_FRAPPE_BRANCH"

  # HRMS
  read -rp " ${YW}Install HRMS module?${CL} [y/N]: " input
  [[ "${input,,}" == "y" ]] && INSTALL_HRMS="yes" || INSTALL_HRMS="no"

  echo
}

# ─── LXC creation ─────────────────────────────────────────────────────────────

download_template() {
  local tmpl_storage
  tmpl_storage=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1{print $1}' | head -1)
  TEMPLATE_STORAGE="${tmpl_storage:-local}"

  msg_info "Fetching available Debian 12 template"
  TEMPLATE=$(pveam available --section system 2>/dev/null | \
    awk '/debian-12-standard/{print $2}' | sort -V | tail -1)
  if [[ -z "$TEMPLATE" ]]; then
    msg_error "Could not find a Debian 12 template in the Proxmox template repository."
    exit 1
  fi

  local already_downloaded
  already_downloaded=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '{print $1}' | grep "$TEMPLATE" || true)
  if [[ -z "$already_downloaded" ]]; then
    msg_info "Downloading $TEMPLATE"
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" &>/dev/null
    msg_ok "Downloaded $TEMPLATE"
  else
    msg_ok "Template $TEMPLATE already present"
  fi

  TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"
}

build_net_string() {
  local net="name=eth0,bridge=${PCT_BRIDGE}"
  if [[ "$PCT_NET" == "dhcp" ]]; then
    net+=",ip=dhcp"
  else
    net+=",ip=${PCT_NET}"
    [[ -n "${PCT_GW:-}" ]] && net+=",gw=${PCT_GW}"
  fi
  [[ -n "${PCT_VLAN:-}" ]] && net+=",tag=${PCT_VLAN}"
  echo "$net"
}

create_lxc() {
  msg_info "Creating LXC container ${PCT_ID}"

  local net_string
  net_string=$(build_net_string)

  local create_args=(
    "$PCT_ID"
    "$TEMPLATE_PATH"
    --hostname    "$PCT_HOSTNAME"
    --cores       "$PCT_CPU"
    --memory      "$PCT_RAM"
    --swap        512
    --rootfs      "${PCT_STORAGE}:${PCT_DISK_SIZE}"
    --net0        "$net_string"
    --unprivileged "$PCT_UNPRIVILEGED"
    --features    "nesting=1,keyctl=1"
    --onboot      1
    --start       0
  )

  [[ -n "$PCT_PASSWORD" ]] && create_args+=(--password "$PCT_PASSWORD")

  pct create "${create_args[@]}" &>/dev/null
  msg_ok "LXC container ${PCT_ID} created"
}

start_lxc() {
  msg_info "Starting LXC container ${PCT_ID}"
  pct start "$PCT_ID"
  # Wait until networking is up
  local attempts=0
  while (( attempts < 20 )); do
    sleep 3
    if pct exec "$PCT_ID" -- bash -c "ip route | grep -q default" 2>/dev/null; then
      break
    fi
    (( attempts++ ))
  done
  msg_ok "Container ${PCT_ID} is running"
}

push_install_script() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local install_script="${script_dir}/install/erpnext-install.sh"

  if [[ ! -f "$install_script" ]]; then
    # Fallback: download from GitHub
    msg_info "Downloading install script"
    local tmp_script
    tmp_script=$(mktemp)
    wget -qO "$tmp_script" \
      "https://raw.githubusercontent.com/jumc1998/ERPNext-Proxmox/main/install/erpnext-install.sh"
    install_script="$tmp_script"
  fi

  msg_info "Pushing install script into container"
  pct push "$PCT_ID" "$install_script" /root/erpnext-install.sh
  pct exec "$PCT_ID" -- chmod +x /root/erpnext-install.sh
  msg_ok "Install script ready inside container"
}

run_install_script() {
  echo -e "\n${BOLD}${BL}Starting ERPNext installation inside container ${PCT_ID}...${CL}\n"
  pct exec "$PCT_ID" -- bash /root/erpnext-install.sh \
    --frappe-branch   "$INSTALL_FRAPPE_BRANCH" \
    --erpnext-branch  "$INSTALL_ERPNEXT_BRANCH" \
    --site-name       "site1.local" \
    --install-hrms    "$INSTALL_HRMS"
}

print_summary() {
  local ip
  ip=$(pct exec "$PCT_ID" -- bash -c \
    "ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet )[\d.]+'" 2>/dev/null || echo "check container")

  echo -e "\n${BOLD}${GN}═══════════════════════════════════════════════${CL}"
  echo -e "${BOLD}${GN}  ERPNext LXC — Installation Complete${CL}"
  echo -e "${BOLD}${GN}═══════════════════════════════════════════════${CL}"
  echo -e " ${CM} Container ID : ${BOLD}${PCT_ID}${CL}"
  echo -e " ${CM} Hostname     : ${BOLD}${PCT_HOSTNAME}${CL}"
  echo -e " ${CM} IP Address   : ${BOLD}${ip}${CL}"
  echo -e " ${CM} Branch       : ${BOLD}${INSTALL_FRAPPE_BRANCH}${CL}"
  echo -e " ${CM} HRMS         : ${BOLD}${INSTALL_HRMS}${CL}"
  echo -e ""
  echo -e " ${INFO} Access ERPNext at: ${BOLD}http://${ip}${CL}"
  echo -e " ${INFO} Default login   : ${BOLD}Administrator${CL} / (set during setup wizard)"
  echo -e " ${INFO} To open a shell : ${BOLD}pct enter ${PCT_ID}${CL}"
  echo -e "${BOLD}${GN}═══════════════════════════════════════════════${CL}\n"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  check_root
  check_proxmox

  echo -e "\n${BOLD}${BL}"
  cat <<'BANNER'
  ███████╗██████╗ ██████╗ ███╗   ██╗███████╗██╗  ██╗████████╗
  ██╔════╝██╔══██╗██╔══██╗████╗  ██║██╔════╝╚██╗██╔╝╚══██╔══╝
  █████╗  ██████╔╝██████╔╝██╔██╗ ██║█████╗   ╚███╔╝    ██║
  ██╔══╝  ██╔══██╗██╔═══╝ ██║╚██╗██║██╔══╝   ██╔██╗    ██║
  ███████╗██║  ██║██║     ██║ ╚████║███████╗██╔╝ ██╗   ██║
  ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝   ╚═╝
          LXC Installer for Proxmox VE
BANNER
  echo -e "${CL}"

  configure_interactively
  download_template
  create_lxc
  start_lxc
  push_install_script
  run_install_script
  print_summary
}

main "$@"
