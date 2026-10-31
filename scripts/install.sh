#!/usr/bin/env bash
# MobileLinux installer. RUN IN: Android / Termux (host), not inside the Debian guest.
#
# Usage: bash scripts/install.sh [options]
#   --profile auto|low|mid|high   hardware profile (default: from config, else auto)
#   --browser auto|none|chromium|firefox   browser to attempt (default: auto = profile default)
#   --code-server                 also try to install code-server via npm (optional, heavy)
#   --skip-apps                   desktop only; skip development tools and browser
#   --skip-upgrade                do not run 'pkg update/upgrade' in Termux
#   -y, --yes                     answer yes to prompts (non-interactive)
#   -h, --help
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
ml_install_traps

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

PROFILE_ARG="" BROWSER="auto" WITH_CODE_SERVER=0 SKIP_APPS=0 SKIP_UPGRADE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)  [[ $# -ge 2 ]] || ml_die "--profile needs a value"; PROFILE_ARG="$2"; shift 2 ;;
    --browser)  [[ $# -ge 2 ]] || ml_die "--browser needs a value"; BROWSER="$2"; shift 2 ;;
    --code-server) WITH_CODE_SERVER=1; shift ;;
    --skip-apps) SKIP_APPS=1; shift ;;
    --skip-upgrade) SKIP_UPGRADE=1; shift ;;
    -y|--yes) ML_ASSUME_YES=1; export ML_ASSUME_YES; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; ml_die "Unknown option: $1" 2 ;;
  esac
done
case "$BROWSER" in auto|none|chromium|firefox) ;; *) ml_die "Invalid --browser value: $BROWSER" 2 ;; esac

on_exit() {
  local rc=$?
  ml_cleanup
  if ((rc != 0 && rc != 130)); then
    ml_err "Installation did not complete (exit status $rc)."
    ml_info "Nothing you created was deleted. You can simply re-run: bash scripts/install.sh"
    ml_info "Common fixes: free storage (df -h), check the network, run 'termux-change-repo' if 'pkg' cannot download,"
    ml_info "then see the Troubleshooting section of README.md."
  fi
}
trap on_exit EXIT

ml_load_config
if [[ -n "$PROFILE_ARG" ]]; then
  ML_PROFILE="$PROFILE_ARG"
  [[ "$ML_PROFILE" == auto ]] || ml_profile_valid "$ML_PROFILE" || ml_die "Unknown profile: $ML_PROFILE" 2
fi

cat >&2 <<'__BANNER__'

MobileLinux installer  (Linux desktop in Termux + PRoot; NOT an Android replacement OS)
  * Needs a working network connection and several GB of free storage (estimate: 4-6 GB).
  * Downloads are done by Termux 'pkg', proot-distro and Debian 'apt' from their own repositories.
  * The first run can take 15-60+ minutes depending on device and network.
  * It may ask you to confirm package upgrades. Existing guest data is kept on re-runs.
  * Keep Termux in the foreground and the screen on; Android may kill background apps.

__BANNER__

ml_step "Checking environment"
ml_is_termux || ml_die "This installer must run inside Termux on Android. (Did you run it in the Debian guest or on a PC?)"
ml_check_arch
for f in scripts/guest/provision.sh scripts/guest/user-setup.sh scripts/guest/install-apps.sh scripts/guest/vncctl.sh configs/vnc/xstartup; do
  [[ -f "$ML_ROOT/$f" ]] || ml_die "Project file missing: $f (re-clone the repository: $ML_REPO_URL)"
done
avail_kb="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
if [[ "$avail_kb" =~ ^[0-9]+$ ]] && ((avail_kb < 3 * 1024 * 1024)); then
  ml_warn "Only about $((avail_kb / 1024)) MiB free in Termux storage; 4+ GiB is recommended."
  ml_confirm "Continue anyway?" || ml_die "Aborted. Free some storage and re-run."
fi

ml_resolve_profile
ml_load_profile "$ML_PROFILE_RESOLVED"
mem_mb="$(ml_detect_mem_mb)"
ml_info "Detected RAM: ${mem_mb} MiB (0 = unknown). Profile setting: ${ML_PROFILE} -> using '${ML_PROFILE_RESOLVED}'"
ml_info "Profile: ${PROFILE_DESCRIPTION:-$ML_PROFILE_RESOLVED}"
ml_info "Guest distro: $ML_DISTRO   guest user: $ML_USER   VNC display: :$ML_VNC_DISPLAY (port $((5900 + ML_VNC_DISPLAY)), localhost only)"
ml_confirm "Proceed with installation?" || ml_die "Aborted by user (or no interactive terminal; use --yes)."
if [[ -n "$PROFILE_ARG" ]]; then
  ml_config_set ML_PROFILE "$ML_PROFILE"
fi

ml_step "Termux packages"
if ((SKIP_UPGRADE == 0)); then
  if ml_confirm "Run 'pkg update' and 'pkg upgrade' now (recommended)?"; then
    pkg update -y || ml_die "'pkg update' failed. Try 'termux-change-repo' to pick a working mirror, then re-run."
    pkg upgrade -y || ml_die "'pkg upgrade' failed. See README Troubleshooting."
  else
    ml_warn "Skipping pkg upgrade. Old Termux packages can cause installation problems."
  fi
fi
if ! ml_have proot-distro; then
  pkg install -y proot-distro || ml_die "Could not install 'proot-distro'. Check network/mirror (termux-change-repo)."
fi
ml_require proot-distro

ml_step "Debian guest (proot-distro)"
if ml_guest_installed; then
  ml_ok "Existing '$ML_DISTRO' guest found; reusing it (no data is removed)."
else
  ml_info "Installing '$ML_DISTRO' with proot-distro (rootfs integrity is handled by proot-distro itself; not re-verified here)."
  proot-distro install "$ML_DISTRO" || ml_die "proot-distro could not install '$ML_DISTRO'. Check storage/network, or run 'proot-distro list'."
fi
ml_guest_exec root true || ml_die "Cannot log in to the '$ML_DISTRO' guest. Try: proot-distro login $ML_DISTRO"

ml_step "Provisioning desktop (runs as root inside the guest)"
ml_guest_exec root bash /opt/MobileLinux/scripts/guest/provision.sh
ml_step "User configuration (runs as '$ML_USER' inside the guest)"
ml_guest_exec "$ML_USER" bash /opt/MobileLinux/scripts/guest/user-setup.sh

if ((SKIP_APPS == 0)); then
  ml_step "Development tools and optional apps (non-fatal if they fail)"
  app_args=(--browser "$BROWSER")
  ((WITH_CODE_SERVER == 1)) && app_args+=(--code-server)
  if ml_guest_exec root bash /opt/MobileLinux/scripts/guest/install-apps.sh "${app_args[@]}"; then
    if ((WITH_CODE_SERVER == 1)); then
      ml_guest_exec "$ML_USER" bash /opt/MobileLinux/scripts/guest/install-code-server.sh \
        || ml_warn "code-server installation failed; the rest of the system is unaffected."
    fi
  else
    ml_warn "install-apps.sh reported problems. The desktop still works; retry with: proot-distro login $ML_DISTRO --bind \"$ML_ROOT:/opt/MobileLinux\" -- bash /opt/MobileLinux/scripts/guest/install-apps.sh"
  fi
fi

ml_step "Done"
cat >&2 <<__NEXT__
Next steps (all in Termux, from the MobileLinux directory):
  1. bash scripts/setup-vnc.sh passwd      # set your VNC password (never stored in this repo)
  2. bash scripts/setup-vnc.sh start       # start the desktop
  3. In an Android VNC client connect to   localhost:$((5900 + ML_VNC_DISPLAY))   (display :$ML_VNC_DISPLAY)
  4. bash scripts/setup-vnc.sh stop        # when finished
VNC authentication is not encryption; the server only listens on localhost. See SECURITY.md.
__NEXT__
