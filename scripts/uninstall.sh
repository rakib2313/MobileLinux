#!/usr/bin/env bash
# Remove the Debian guest. RUN IN: Termux (host). DESTRUCTIVE: deletes ALL guest data,
# including the guest user's home directory (projects, VNC password, code-server config).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
ml_install_traps
ml_load_config
ml_is_termux || ml_die "Run this script in Termux (host)."
ml_have proot-distro || ml_die "proot-distro is not installed; nothing to remove."

ml_warn "This will PERMANENTLY delete the '$ML_DISTRO' guest and everything inside it (/home/$ML_USER, /root, installed packages)."
ml_info "Back up first if you need your files, for example copy them to shared storage, or (if your proot-distro supports it):"
ml_info "  proot-distro backup $ML_DISTRO --output \"\$HOME/${ML_DISTRO}-backup.tar.gz\""
if ! ml_guest_installed; then
  ml_info "Guest '$ML_DISTRO' is not installed. Nothing to do."
  exit 0
fi
[[ -t 0 ]] || ml_die "Refusing to run without an interactive terminal."
read -r -p "Type the guest name ('$ML_DISTRO') to confirm deletion, anything else cancels: " answer
if [[ "$answer" != "$ML_DISTRO" ]]; then
  ml_info "Cancelled. Nothing was deleted."
  exit 0
fi
bash "$SCRIPT_DIR/setup-vnc.sh" stop || ml_warn "Could not stop VNC (it may not be running)."
proot-distro remove "$ML_DISTRO"
ml_ok "Guest '$ML_DISTRO' removed."
if [[ -d "$ML_CONFIG_DIR" ]] && ml_confirm "Also delete MobileLinux settings in $ML_CONFIG_DIR?"; then
  rm -rf -- "$ML_CONFIG_DIR"
  ml_ok "Settings removed."
fi
ml_info "The MobileLinux repository directory itself was not touched; delete it manually if you wish."
