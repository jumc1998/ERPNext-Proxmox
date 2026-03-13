# ERPNext LXC — Proxmox VE Helper Scripts

Automated scripts to deploy **ERPNext** (v14 / v15) inside a **Debian 12 LXC** container on **Proxmox VE 7+**.

---

## What's included

| File | Purpose |
|---|---|
| `ct/erpnext.sh` | Runs on the **Proxmox host** — creates the LXC and triggers the install |
| `install/erpnext-install.sh` | Runs **inside the container** — installs all dependencies and ERPNext |
| `misc/update.sh` | Runs **inside the container** — updates Frappe/ERPNext to the latest patch |

---

## Quick start (one-liner)

Run this on your **Proxmox VE host** as root:

```bash
bash -c "$(wget -qO - https://raw.githubusercontent.com/jumc1998/ERPNext-Proxmox/main/ct/erpnext.sh)"
```

The script will guide you through an interactive setup and then fully automate the deployment.

---

## LXC defaults

| Setting | Default |
|---|---|
| OS | Debian 12 (Bookworm) |
| CPU cores | 4 |
| RAM | 6 144 MiB |
| Disk | 40 GiB |
| Unprivileged | yes (nesting + keyctl) |
| ERPNext branch | version-15 |
| Site name | site1.local |

You will be prompted to change any of these during setup.

---

## What the install script does

1. **System update** — apt update & upgrade
2. **Base packages** — git, curl, build tools, wkhtmltopdf, fonts
3. **Node.js 20** — via NodeSource; installs Yarn globally
4. **MariaDB 10.11** — secure install, charset utf8mb4, Frappe-required settings
5. **Redis** — enabled as a system service
6. **Frappe Bench CLI** — installed via pip3
7. **`frappe` system user** — with scoped sudo rules
8. **Bench init** — fresh Frappe bench at `/home/frappe/frappe-bench`
9. **ERPNext app** — fetched from GitHub at the selected branch
10. **HRMS app** *(optional)* — fetched and installed on the site
11. **Site creation** — new Frappe site with random secure passwords
12. **App install** — ERPNext (and optionally HRMS) installed on the site
13. **Production setup** — nginx + supervisor configured and started
14. **Scheduler** — enabled for background jobs
15. **fail2ban** — installed and enabled
16. **Credentials saved** — to `/root/erpnext-credentials.txt` (chmod 600)

---

## Manual installation (run inside the container yourself)

```bash
# Copy the script into the container
pct push <CTID> install/erpnext-install.sh /root/erpnext-install.sh
pct exec <CTID> -- chmod +x /root/erpnext-install.sh

# Run with defaults (version-15, site1.local, no HRMS)
pct exec <CTID> -- bash /root/erpnext-install.sh

# Or customise
pct exec <CTID> -- bash /root/erpnext-install.sh \
  --frappe-branch  version-15 \
  --erpnext-branch version-15 \
  --site-name      mycompany.local \
  --install-hrms   yes
```

### Available arguments

| Argument | Default | Description |
|---|---|---|
| `--frappe-branch` | `version-15` | Frappe framework branch |
| `--erpnext-branch` | `version-15` | ERPNext app branch |
| `--site-name` | `site1.local` | Frappe site name |
| `--install-hrms` | `no` | Install HRMS module (`yes`/`no`) |
| `--admin-password` | *(random)* | Override the generated Administrator password |

---

## Accessing ERPNext

After installation, find the container IP with:

```bash
pct exec <CTID> -- ip -4 addr show eth0
```

Then open `http://<container-ip>` in your browser.

- **Username:** `Administrator`
- **Password:** shown at end of install, also in `/root/erpnext-credentials.txt`

---

## Updating ERPNext

Run the bundled update script inside the container:

```bash
pct exec <CTID> -- bash /path/to/misc/update.sh --site site1.local
```

Or manually:

```bash
pct enter <CTID>
su - frappe
cd ~/frappe-bench
bench update --site site1.local
```

---

## Supported versions

| ERPNext | Frappe | Python | Node.js | MariaDB |
|---|---|---|---|---|
| v15 | v15 | 3.11 | 20 | 10.11 |
| v14 | v14 | 3.10 | 18+ | 10.6+ |

---

## Requirements

- Proxmox VE **7.0** or newer
- At least **4 CPU cores**, **6 GB RAM**, and **40 GB disk** available for the container
- Internet access from the Proxmox host and from inside the container

---

## License

MIT
