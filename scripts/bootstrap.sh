#!/usr/bin/env bash
# =============================================================================
# Cobbler Setup — Bootstrap Wrapper
# Validates prerequisites and runs Ansible playbooks in sequence.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PLAYBOOK_DIR="$REPO_DIR/ansible/playbooks"
INVENTORY="$REPO_DIR/ansible/inventory/hosts.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# --- Check prerequisites ---
if ! command -v ansible-playbook &>/dev/null; then
    log_error "ansible-playbook not found. Install Ansible first:"
    echo "  pip3 install ansible"
    exit 1
fi

if [[ ! -f "$INVENTORY" ]]; then
    log_error "Inventory file not found: $INVENTORY"
    echo ""
    echo "  Copy the template and fill in your values:"
    echo "  cp $REPO_DIR/ansible/inventory/hosts.yml.template $INVENTORY"
    echo "  vim $INVENTORY"
    exit 1
fi

# --- Usage ---
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --all           Run all playbooks (00 through 04)"
    echo "  --preflight     Run only 00-preflight.yml"
    echo "  --install       Run only 01-install-cobbler.yml"
    echo "  --configure     Run only 02-configure-cobbler.yml"
    echo "  --import        Run only 03-import-iso.yml"
    echo "  --verify        Run only 04-verify.yml"
    echo "  -h, --help      Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 --all                  # Full setup"
    echo "  $0 --preflight            # Check prerequisites only"
    echo "  $0 --import               # Import ISO after placing it on server"
    exit 0
}

run_playbook() {
    local playbook="$1"
    local name="$2"

    log_info "Running: $name"
    echo "---"

    ansible-playbook -i "$INVENTORY" "$PLAYBOOK_DIR/$playbook"

    echo "---"
    log_info "Completed: $name"
    echo ""
}

# --- Parse arguments ---
if [[ $# -eq 0 ]]; then
    usage
fi

case "${1:-}" in
    --all)
        log_info "=== Cobbler Full Bootstrap ==="
        echo ""

        read -rp "This will install and configure Cobbler on the target server. Continue? [y/N] " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            log_warn "Aborted."
            exit 0
        fi
        echo ""

        run_playbook "00-preflight.yml" "Preflight checks"
        run_playbook "01-install-cobbler.yml" "Install Cobbler"
        run_playbook "02-configure-cobbler.yml" "Configure Cobbler"
        run_playbook "03-import-iso.yml" "Import RHEL 9 ISO"
        run_playbook "04-verify.yml" "Verify setup"

        log_info "=== Cobbler Bootstrap Complete ==="
        echo ""
        echo "Next steps:"
        echo "  1. PXE boot a machine on the provisioning network"
        echo "  2. It will get a DHCP lease and load the Cobbler boot menu"
        echo "  3. RHEL 9 installs automatically via kickstart"
        ;;
    --preflight)
        run_playbook "00-preflight.yml" "Preflight checks"
        ;;
    --install)
        run_playbook "01-install-cobbler.yml" "Install Cobbler"
        ;;
    --configure)
        run_playbook "02-configure-cobbler.yml" "Configure Cobbler"
        ;;
    --import)
        run_playbook "03-import-iso.yml" "Import RHEL 9 ISO"
        ;;
    --verify)
        run_playbook "04-verify.yml" "Verify setup"
        ;;
    -h|--help)
        usage
        ;;
    *)
        log_error "Unknown option: $1"
        usage
        ;;
esac
