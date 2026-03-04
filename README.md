# Cobbler PXE Provisioning Server

Automated setup of a [Cobbler](https://cobbler.github.io/) server on Rocky Linux 9 that acts as a DHCP + PXE boot server to discover and install RHEL 9 on bare-metal machines.

## Overview

When a machine PXE boots on the provisioning network, Cobbler:

1. Hands out a DHCP lease with the address of the TFTP server
2. Serves the correct bootloader (UEFI or Legacy BIOS — auto-detected)
3. Loads the RHEL 9 kernel and initrd
4. Anaconda (the RHEL installer) fetches a kickstart file from Cobbler over HTTP
5. RHEL 9 installs unattended — partitions, packages, post-install config
6. After install, PXE is disabled for that host so it boots from disk

## Architecture

```
                    192.168.1.0/24 (Provisioning Network)
                    ┌──────────────────────────────────────┐
                    │                                      │
┌───────────────┐   │   ┌──────────┐    ┌──────────┐       │
│ Cobbler Server│   │   │ Server A │    │ Server B │  ...  │
│ 192.168.5.7   │───┤   │ PXE Boot │    │ PXE Boot │       │
│ 192.168.1.79  │   │   └──────────┘    └──────────┘       │
│ (ens192)      │   │                                      │
└───────────────┘   └──────────────────────────────────────┘

Services on Cobbler:
  - DHCP  (port 67/68)  — hands out IPs + PXE boot info
  - TFTP  (port 69)     — serves bootloaders, kernel, initrd
  - HTTP  (port 80)     — serves kickstart files + RHEL 9 repo mirror
  - Cobbler API (25151) — management interface
```

## Prerequisites

| Requirement | Details |
|-------------|---------|
| Cobbler server OS | Rocky Linux 9 |
| Server IP | `192.168.5.7` (management) + `192.168.1.79` (provisioning) |
| NIC | `ens192` (both IPs on this interface) |
| Disk space | 15 GB free on `/var` (for RHEL 9 repo mirror) |
| SELinux | Must be `permissive` or `disabled` |
| RHEL 9 ISO | Download from [access.redhat.com](https://access.redhat.com/downloads/content/rhel) |
| Ansible | Installed on the machine running playbooks |
| SSH access | Root access to the Cobbler server |

### Adding the secondary IP (provisioning subnet)

The Cobbler server needs an IP on the provisioning network (`192.168.1.0/24`):

```bash
nmcli connection modify ens192 +ipv4.addresses "192.168.1.79/24"
nmcli connection up ens192
```

To remove it later: `nmcli connection modify ens192 -ipv4.addresses "192.168.1.79/24"`

### Downloading the RHEL 9 ISO

1. Create a free [Red Hat Developer account](https://developers.redhat.com/)
2. Go to [RHEL Downloads](https://access.redhat.com/downloads/content/rhel)
3. Select RHEL 9 > x86_64 > DVD ISO (~10 GB)
4. Right-click download button > Copy link
5. On the Cobbler server:
   ```bash
   curl -o /root/rhel-9-x86_64-dvd.iso '<paste-download-URL>'
   ```

### Setting SELinux to permissive

```bash
setenforce 0
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

## Quick Start

```bash
# 1. Clone the repo
git clone <repo-url> cobbler-setup
cd cobbler-setup

# 2. Create inventory from template
cp ansible/inventory/hosts.yml.template ansible/inventory/hosts.yml

# 3. Review and edit variables
vim ansible/inventory/group_vars/all.yml

# 4. Generate the root password hash for provisioned hosts
python3 -c "import crypt; print(crypt.crypt('yourpassword', crypt.mksalt(crypt.METHOD_SHA512)))"
# Paste the output into all.yml -> cobbler_default_password_crypted

# 5. Run the full setup
./scripts/bootstrap.sh --all
```

## Playbook Reference

| Playbook | What it does | Run individually |
|----------|-------------|------------------|
| `00-preflight.yml` | Validates OS, disk, NIC, SELinux, connectivity | `./scripts/bootstrap.sh --preflight` |
| `01-install-cobbler.yml` | Installs Cobbler 3.3.7 + all dependencies | `./scripts/bootstrap.sh --install` |
| `02-configure-cobbler.yml` | Deploys settings, DHCP template, kickstart, firewall | `./scripts/bootstrap.sh --configure` |
| `03-import-iso.yml` | Imports RHEL 9 ISO into Cobbler | `./scripts/bootstrap.sh --import` |
| `04-verify.yml` | Checks all services, TFTP files, HTTP mirror | `./scripts/bootstrap.sh --verify` |

Or run the master playbook directly:

```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/site.yml
```

## Roles

### preflight

Validates the Cobbler server meets all prerequisites before making any changes.

**Checks performed:**
- OS is Rocky Linux 9
- At least 15 GB free on `/var` (ISO mirror needs ~10 GB)
- Provisioning NIC exists and has the configured IP
- SELinux is permissive or disabled
- Internet connectivity to EPEL repository

### cobbler-install

Installs Cobbler and all required packages from EPEL.

**Key actions:**
- Enables EPEL, CRB, and HighAvailability repositories
- Installs: `cobbler`, `dhcp-server`, `tftp-server`, `syslinux`, `shim-x64`, `grub2-efi-x64`, `createrepo_c`, `fence-agents-all`, `httpd`
- Enables and starts: `cobblerd`, `httpd`, `tftp.socket`

**Why HighAvailability repo?** Rocky 9 moved `fence-agents` to this repo. Without it, `dnf install cobbler` fails.

### cobbler-configure

Deploys all configuration files and templates.

**Files deployed:**
- `/etc/cobbler/settings.yaml` — Master config (server IP, DHCP management, PXE behavior)
- `/etc/cobbler/modules.conf` — Backend modules (ISC DHCP, in.tftpd)
- `/etc/cobbler/dhcp.template` — DHCP config with UEFI/BIOS auto-detection
- `/var/lib/cobbler/templates/kickstart-rhel9.ks` — Unattended RHEL 9 install template

**UEFI/BIOS auto-detection:** The DHCP template uses option 93 (pxe-system-type) to detect firmware:
- UEFI (0x0007/0x0008/0x0009) -> serves `shimx64.efi` (Secure Boot compatible)
- Legacy BIOS -> serves `pxelinux.0`

**Kickstart partitioning (works on both UEFI and BIOS):**
- `/boot/efi` — 512 MB (UEFI only, auto-skipped on BIOS)
- `biosboot` — 1 MB (BIOS+GPT only, auto-skipped on UEFI)
- `/boot` — 1 GB XFS (outside LVM)
- LVM: root (fill disk) + swap (4 GB)

Also runs `cobbler mkloaders` (builds GRUB EFI bootloaders) and `cobbler sync`.

### cobbler-firewall

Replaces `firewalld` with `nftables` and opens only required ports.

| Port | Protocol | Source | Service |
|------|----------|--------|---------|
| 22 | TCP | Management CIDR | SSH |
| 67/68 | UDP | Any | DHCP (PXE clients have no IP) |
| 69 | UDP | Any | TFTP (boot file download) |
| 80 | TCP | Any | HTTP (kickstart + repo mirror) |
| 443 | TCP | Any | HTTPS (optional) |
| 25151 | TCP | Management CIDR | Cobbler API |

### cobbler-import

Mounts the RHEL 9 DVD ISO and imports it into Cobbler.

**What happens:**
1. Validates ISO exists at configured path
2. Mounts ISO read-only at `/mnt/rhel9-dvd`
3. `cobbler import` copies ~10 GB to `/var/www/cobbler/distro_mirror/rhel9-x86_64/`
4. Creates distro + profile objects in Cobbler
5. Assigns kickstart template to the profile
6. Runs `cobbler sync` to regenerate DHCP/TFTP configs
7. Unmounts ISO

Idempotent — skips import if distro already exists.

### cobbler-verify

End-to-end health check after setup.

**Checks:**
- Services running: `cobblerd`, `httpd`, `dhcpd`, `tftp.socket`
- `cobbler check` self-diagnostic
- Distro and profile registered
- TFTP boot files present: `pxelinux.0`, `shimx64.efi`, `grubx64.efi`, `vmlinuz`, `initrd.img`
- HTTP repo mirror returns HTTP 200
- DHCP config contains correct subnet and boot filenames

## Network Configuration

### Current Setup

```
Cobbler Server (dns):
  ens192:
    - 192.168.5.7/24   (management — DNS, SSH, Ansible)
    - 192.168.1.79/24   (provisioning — DHCP, TFTP, HTTP for PXE)

Provisioning subnet: 192.168.1.0/24
  Gateway:   192.168.1.254
  DHCP pool: 192.168.1.80 — 192.168.1.117 (38 addresses)
  DNS:       192.168.5.7, 192.168.5.1
  Domain:    sgs.com
```

### Used IPs on 192.168.1.0/24 (avoid these)

66, 67, 68, 70, 71, 72, 76, 78, 79 (Cobbler), 118, 213, 229, 243, 244, 253, 254 (gateway)

## Configuration Variables

All variables are in `ansible/inventory/group_vars/all.yml`. Key settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `cobbler_server_ip` | `192.168.5.7` | Management IP (SSH, Ansible) |
| `cobbler_pxe_ip` | `192.168.1.79` | Provisioning IP (DHCP, TFTP, HTTP) |
| `cobbler_interface` | `ens192` | Network interface |
| `cobbler_subnet` | `192.168.1.0` | Provisioning subnet |
| `cobbler_netmask` | `255.255.255.0` | Subnet mask |
| `cobbler_dhcp_range_start` | `192.168.1.80` | DHCP pool start |
| `cobbler_dhcp_range_end` | `192.168.1.117` | DHCP pool end |
| `cobbler_gateway` | `192.168.1.254` | Default gateway for provisioned hosts |
| `cobbler_dns_servers` | `192.168.5.7, 192.168.5.1` | DNS servers |
| `cobbler_domain` | `sgs.com` | DNS domain |
| `cobbler_iso_path` | `/root/rhel-9-x86_64-dvd.iso` | RHEL 9 ISO location on server |
| `cobbler_distro_name` | `rhel9` | Cobbler distro name |
| `cobbler_install_disk` | `sda` | Target disk for installs |
| `cobbler_timezone` | `America/New_York` | Timezone |
| `cobbler_pxe_just_once` | `true` | Prevent PXE boot loops |
| `cobbler_default_password_crypted` | (placeholder) | Root password hash |

## PXE Boot Flow

```
Machine powers on
    │
    ▼
NIC sends DHCP broadcast
    │
    ▼
Cobbler DHCP responds with:
  - IP from pool (192.168.1.80-117)
  - TFTP server: 192.168.1.79
  - Boot file: shimx64.efi (UEFI) or pxelinux.0 (BIOS)
    │
    ▼
Machine TFTPs bootloader from Cobbler
    │
    ├── UEFI: shimx64.efi -> grubx64.efi -> GRUB menu
    └── BIOS: pxelinux.0 -> PXE menu
    │
    ▼
Boot menu shows "rhel9-x86_64" profile
    │
    ▼
Loads vmlinuz + initrd.img -> Anaconda starts
    │
    ▼
Anaconda fetches kickstart from:
  http://192.168.1.79/cblr/svc/op/autoinstall/profile/rhel9-x86_64
    │
    ▼
Unattended RHEL 9 install runs:
  - Partitions disk (LVM: root + swap)
  - Installs packages (minimal + extras)
  - Configures NTP, SSH, SELinux
    │
    ▼
Install complete -> Cobbler disables PXE for this host
    │
    ▼
Machine reboots from disk
```

## Post-Install: Adding Specific Systems

After the basic setup, you can register specific systems with fixed IPs and hostnames:

```bash
# Add a system with a fixed IP (instead of DHCP pool)
cobbler system add \
  --name=server01 \
  --profile=rhel9-x86_64 \
  --mac=AA:BB:CC:DD:EE:FF \
  --ip-address=192.168.1.120 \
  --hostname=server01.sgs.com \
  --gateway=192.168.1.254 \
  --name-servers="192.168.5.7 192.168.5.1" \
  --interface=ens192

# Apply changes
cobbler sync

# List registered systems
cobbler system list

# View system details
cobbler system report --name=server01
```

## Troubleshooting

### Machine not getting DHCP lease
```bash
# Check dhcpd is running
systemctl status dhcpd

# Check DHCP logs
journalctl -u dhcpd -f

# Verify DHCP config
cat /etc/dhcp/dhcpd.conf | grep -A5 "subnet"
```

### TFTP download fails
```bash
# Check tftp is listening
ss -ulnp | grep :69

# Test TFTP locally
tftp 192.168.1.79 -c get pxelinux.0

# Check boot files exist
ls -la /srv/tftpboot/pxelinux.0
ls -la /srv/tftpboot/grub/shimx64.efi
```

### Kickstart not loading
```bash
# Test HTTP access
curl -I http://192.168.1.79/cobbler/distro_mirror/rhel9-x86_64/

# Check cobblerd is running
systemctl status cobblerd

# Check Apache logs
tail -f /var/log/httpd/error_log
```

### Cobbler general diagnostics
```bash
# Self-check
cobbler check

# List distros and profiles
cobbler distro list
cobbler profile list

# Resync everything
cobbler sync
```

## Directory Structure

```
cobbler-setup/
├── .gitignore
├── README.md
├── ansible.cfg
├── ansible/
│   ├── inventory/
│   │   ├── hosts.yml.template          # Copy to hosts.yml, fill in values
│   │   └── group_vars/
│   │       └── all.yml                 # All configurable variables
│   ├── playbooks/
│   │   ├── site.yml                    # Master playbook (runs all)
│   │   ├── 00-preflight.yml            # Validate prerequisites
│   │   ├── 01-install-cobbler.yml      # Install packages
│   │   ├── 02-configure-cobbler.yml    # Deploy configs + firewall
│   │   ├── 03-import-iso.yml           # Import RHEL 9 ISO
│   │   └── 04-verify.yml              # Health checks
│   └── roles/
│       ├── preflight/                  # OS, disk, NIC, SELinux checks
│       ├── cobbler-install/            # EPEL, packages, services
│       ├── cobbler-configure/          # settings.yaml, DHCP, kickstart
│       │   └── templates/
│       │       ├── settings.yaml.j2
│       │       ├── modules.conf.j2
│       │       ├── dhcp.template.j2
│       │       └── kickstart-rhel9.ks.j2
│       ├── cobbler-firewall/           # nftables rules
│       │   └── templates/
│       │       └── nftables-cobbler.conf.j2
│       ├── cobbler-import/             # ISO mount, import, profile setup
│       └── cobbler-verify/             # End-to-end verification
└── scripts/
    └── bootstrap.sh                    # CLI wrapper for playbooks
```

## Software Versions

| Component | Version |
|-----------|---------|
| Cobbler | 3.3.7 (EPEL) |
| Rocky Linux (server) | 9.x |
| RHEL (target installs) | 9.x |
| ISC DHCP | 4.4.x (Rocky 9 default) |
| Apache httpd | 2.4.x (Rocky 9 default) |
| GRUB2 | 2.06 (Rocky 9 default) |
