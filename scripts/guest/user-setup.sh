#!/usr/bin/env bash
# Per-user configuration. RUN IN: Debian guest, as the unprivileged desktop user.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
ml_install_traps

[[ "$(id -u)" -ne 0 ]] || ml_die "user-setup.sh must run as the normal desktop user, not root."
ml_load_config
ml_resolve_profile
ml_load_profile "$ML_PROFILE_RESOLVED"

install -d -m 700 "$HOME/.vnc" "$HOME/.config/mobilelinux"

src="$ML_ROOT/configs/vnc/xstartup"
dst="$HOME/.vnc/xstartup"
if [[ ! -e "$dst" ]]; then
  install -m 755 "$src" "$dst"
  ml_ok "Installed $dst"
elif cmp -s "$src" "$dst"; then
  ml_ok "$dst is up to date."
else
  install -m 755 "$src" "$dst.mobilelinux.new"
  ml_warn "$dst already exists and differs; it was NOT replaced. The project version is at $dst.mobilelinux.new"
fi

xfwm_dir="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
xfwm_file="$xfwm_dir/xfwm4.xml"
if [[ -e "$xfwm_file" ]]; then
  ml_info "Existing window-manager settings kept ($xfwm_file). Change compositing in Settings > Window Manager Tweaks."
else
  install -d -m 755 "$xfwm_dir"
  cat >"$xfwm_file" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="${ML_COMPOSITING}"/>
  </property>
</channel>
XML
  ml_ok "Wrote $xfwm_file (compositing=${ML_COMPOSITING}, profile ${ML_PROFILE_RESOLVED})."
fi

ml_ok "User setup complete. Set a VNC password from Termux: bash scripts/setup-vnc.sh passwd"
