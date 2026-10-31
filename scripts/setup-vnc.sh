#!/usr/bin/env bash
# VNC manager. RUN IN: Termux (host). It calls scripts/guest/vncctl.sh inside the Debian guest.
# Usage: bash scripts/setup-vnc.sh <command>
#   passwd              set/change the VNC password (interactive; stored only in the guest, mode 600)
#   start | stop | restart | status
#   resolution WxH      set a custom resolution (e.g. 1280x720) or 'reset' to use the profile default
#   profile low|mid|high|auto|show   same as scripts/select-profile.sh
# The server listens on localhost only. VNC password authentication does NOT encrypt traffic.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
ml_install_traps
ml_load_config

usage() { sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

guest_vnc() {
  ml_is_termux || ml_die "Run this script in Termux (host), not inside the Debian guest."
  ml_guest_installed || ml_die "The '$ML_DISTRO' guest is not installed. Run: bash scripts/install.sh"
  ml_guest_exec "$ML_USER" bash /opt/MobileLinux/scripts/guest/vncctl.sh "$@"
}

cmd="${1:-help}"
case "$cmd" in
  start)
    guest_vnc start
    ml_info "Connect your VNC client to localhost:$((5900 + ML_VNC_DISPLAY)) (this phone only)."
    ;;
  stop|restart|status|passwd) guest_vnc "$cmd" ;;
  resolution)
    arg="${2:-}"
    if [[ "$arg" == reset ]]; then
      ml_config_unset ML_GEOMETRY_OVERRIDE
      ml_ok "Resolution override removed; the profile default is used."
    elif [[ "$arg" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]]; then
      ml_config_set ML_GEOMETRY_OVERRIDE "$arg"
      ml_ok "Resolution set to $arg."
    else
      ml_die "Usage: resolution WIDTHxHEIGHT | reset   (example: resolution 1280x720)" 2
    fi
    ml_info "Apply with: bash scripts/setup-vnc.sh restart"
    ;;
  profile) shift; exec bash "$SCRIPT_DIR/select-profile.sh" "${1:-show}" ;;
  help|-h|--help) usage ;;
  *) usage >&2; ml_die "Unknown command: $cmd" 2 ;;
esac
