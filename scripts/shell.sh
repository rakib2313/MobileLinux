#!/usr/bin/env bash
# Open a shell in the Debian guest. RUN IN: Termux (host).
# Usage: bash scripts/shell.sh [--root]
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
ml_install_traps
ml_load_config
ml_is_termux || ml_die "Run this script in Termux (host)."
ml_guest_installed || ml_die "The '$ML_DISTRO' guest is not installed. Run: bash scripts/install.sh"
user="$ML_USER"
if [[ "${1:-}" == --root ]]; then
  user=root
  ml_warn "Opening a root shell in the guest (root inside PRoot is not real Android root)."
fi
ml_info "Entering guest as '$user'. Type 'exit' to return to Termux. The project is at /opt/MobileLinux."
ml_guest_exec "$user" bash -l
