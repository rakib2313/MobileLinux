#!/usr/bin/env bash
# Guest provisioning. RUN IN: Debian guest, as root (called by scripts/install.sh).
# Installs a minimal XFCE desktop + TigerVNC and creates the unprivileged desktop user.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
ml_install_traps

[[ "$(id -u)" -eq 0 ]] || ml_die "provision.sh must run as root inside the Debian guest."
[[ -f /etc/debian_version ]] || ml_die "This script expects a Debian-based guest."
ml_require apt-get apt-cache useradd
ml_load_config
ml_resolve_profile
ml_load_profile "$ML_PROFILE_RESOLVED"
export DEBIAN_FRONTEND=noninteractive

ml_step "Updating package lists (guest)"
apt-get update || ml_die "apt-get update failed. Check the network. If you see sandbox/seteuid errors under PRoot, see README Troubleshooting."

REQUIRED_PACKAGES=(
  ca-certificates procps iproute2 dbus-x11 xauth x11-xserver-utils xdg-utils
  tigervnc-standalone-server tigervnc-common tigervnc-tools
  xfce4-session xfwm4 xfdesktop4 xfce4-panel xfce4-settings xfce4-appfinder
  xfce4-terminal thunar mousepad xfconf
  fonts-dejavu-core adwaita-icon-theme
)

ml_step "Checking package availability"
missing=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
  ml_apt_available "$pkg" || missing+=("$pkg")
done
if ((${#missing[@]} > 0)); then
  ml_die "These required packages are not available in this Debian guest: ${missing[*]}. Try 'apt-get update' again or check the release."
fi

ml_step "Installing XFCE + TigerVNC (this can take a while)"
apt-get install -y --no-install-recommends "${REQUIRED_PACKAGES[@]}" \
  || ml_die "Package installation failed. Re-run scripts/install.sh; if it persists, check free storage (df -h) and network."

if [[ -n "${ML_EXTRA_PACKAGES// /}" ]]; then
  ml_step "Installing profile extras ($ML_PROFILE_RESOLVED): $ML_EXTRA_PACKAGES"
  # shellcheck disable=SC2086  # word splitting of the package list is intended
  ml_apt_install_optional $ML_EXTRA_PACKAGES
fi

ml_step "Desktop user '$ML_USER'"
if id "$ML_USER" >/dev/null 2>&1; then
  ml_ok "User '$ML_USER' already exists; leaving it unchanged."
else
  useradd -m -s /bin/bash "$ML_USER" || ml_die "Could not create user '$ML_USER'."
  ml_ok "Created user '$ML_USER' (no password; log in via proot-distro --user)."
fi

ml_ok "Provisioning complete (profile: $ML_PROFILE_RESOLVED)."
