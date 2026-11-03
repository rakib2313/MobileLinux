#!/usr/bin/env bash
# =============================================================================
# install.sh - MobileLinux master installer (runs in Termux on Android)
#   1 Welcome + device checks        5 Development tools
#   2 Termux dependencies            6 Optional AI helper
#   3 Debian PRoot setup             7 Optional Termux theme
#   4 Desktop + VNC                  8 Final verification
# Recommended: clone the repository, read the scripts, then run this file:
#   pkg install -y git
#   git clone https://github.com/rakib2313/MobileLinux.git
#   cd MobileLinux && bash scripts/install.sh
# =============================================================================
set -Eeuo pipefail

MLD_REPO_URL="${MLD_REPO_URL:-https://github.com/rakib2313/MobileLinux.git}"
MLD_BRANCH="${MLD_BRANCH:-main}"

_self="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_self")" 2>/dev/null && pwd || true)"

# ---- Bootstrap when piped from curl (no local checkout) ---------------------
if [ -z "$SCRIPT_DIR" ] || [ ! -f "$SCRIPT_DIR/lib/common.sh" ]; then
  echo "[mld] No local checkout found - fetching ${MLD_REPO_URL} ..." >&2
  if ! command -v git >/dev/null 2>&1; then
    pkg install -y git || { echo "[mld] Could not install git." >&2; exit 1; }
  fi
  SRC="${HOME}/.mld-src"
  if [ -d "$SRC/.git" ]; then
    git -C "$SRC" pull --ff-only
  elif [ -e "$SRC" ]; then
    echo "[mld] $SRC exists but is not a git checkout; move it away and retry." >&2
    exit 1
  else
    git clone --depth 1 --branch "$MLD_BRANCH" "$MLD_REPO_URL" "$SRC"
  fi
  if [ -t 0 ]; then
    exec bash "$SRC/scripts/install.sh" "$@"
  elif [ -r /dev/tty ] && ( : </dev/tty ) 2>/dev/null; then
    exec bash "$SRC/scripts/install.sh" "$@" </dev/tty
  else
    exec bash "$SRC/scripts/install.sh" "$@"
  fi
fi

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/ui.sh
. "$SCRIPT_DIR/lib/ui.sh"
mld_enable_traps

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
MLD_HOME="${MLD_HOME:-$HOME/.mld}"
MLD_DISTRO="debian"
MLD_USER="${MLD_USER:-dev}"
PROFILE_ARG=""
REFRESH=0
PROFILE="low"
WANT_THEME=ask      # ask | yes | no
WANT_AI=ask         # ask | yes | no
WANT_NOSANDBOX=ask  # ask | yes (only via --allow-no-sandbox or explicit consent)
WITH_CODE_SERVER=1
THEME_STATE=skipped
AI_STATE=skipped
UI_INSTALL_CMD="bash ${REPO_ROOT}/scripts/install.sh"
UI_DIAG_CMD="bash ${REPO_ROOT}/scripts/diagnose.sh"

usage() {
  cat <<'EOF'
Usage: install.sh [options]
  --profile low|mid|high|auto   Performance profile (default: auto-detect from RAM)
  -y, --yes                     Answer "yes" to ordinary confirmations
                                (never to theme or browser-sandbox consent)
  -v, --verbose                 Stream live command output instead of a spinner
  --no-animation                Disable logo reveal and spinner (plain progress lines)
  --no-color                    Disable colours (NO_COLOR=1 also works)
  --ascii                       Use plain ASCII symbols instead of Unicode
  --no-code-server              Skip code-server (VS Code in the browser)
  --ai                          Offer AI helper setup without asking first
  --no-ai                       Skip the AI helper question
  --theme                       Apply the optional Termux theme (counts as consent)
  --no-theme                    Skip the Termux theme question
  --allow-no-sandbox            Disable browser sandboxes (PRoot limitation; RISKY, see SECURITY.md)
  --refresh                     Only re-sync scripts/configs from this checkout
  -h, --help                    Show this help

Environment: MLD_USER, MLD_PROFILE, MLD_VNC_PASSWORD, MLD_NO_ANIM, MLD_NO_COLOR,
             MLD_ASCII, MLD_LOG_FILE, MLD_REPO_URL, MLD_BRANCH
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile)
        [ $# -ge 2 ] || die "--profile needs a value"
        PROFILE_ARG="$2"; shift 2 ;;
      --profile=*) PROFILE_ARG="${1#*=}"; shift ;;
      -y|--yes) export MLD_ASSUME_YES=1; shift ;;
      -v|--verbose) export MLD_VERBOSE=1; shift ;;
      --no-animation) export MLD_NO_ANIM=1; shift ;;
      --no-color) export MLD_NO_COLOR=1; shift ;;
      --ascii) export MLD_ASCII=1; shift ;;
      --no-code-server) WITH_CODE_SERVER=0; shift ;;
      --ai) WANT_AI=yes; shift ;;
      --no-ai) WANT_AI=no; shift ;;
      --theme) WANT_THEME=yes; shift ;;
      --no-theme) WANT_THEME=no; shift ;;
      --allow-no-sandbox) WANT_NOSANDBOX=yes; shift ;;
      --refresh) REFRESH=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
  done
}

resolve_profile() {
  local stored=""
  PROFILE="${PROFILE_ARG:-${MLD_PROFILE:-}}"
  if [ -z "$PROFILE" ] && [ "$REFRESH" = 1 ] && [ -r "$MLD_HOME/mld.env" ]; then
    stored="$( . "$MLD_HOME/mld.env" 2>/dev/null; printf '%s' "${MLD_PROFILE:-}" )"
    PROFILE="$stored"
  fi
  PROFILE="${PROFILE:-auto}"
  case "$PROFILE" in
    auto) PROFILE="$(mld_pick_profile)" ;;
    low|mid|high) ;;
    *) die "Invalid profile '$PROFILE' (use low, mid, high or auto)" ;;
  esac
  [ -f "$REPO_ROOT/configs/profiles/${PROFILE}.conf" ] || die "Missing profile file for '$PROFILE'"
  [[ "$MLD_USER" =~ ^[a-z][a-z0-9_-]{0,30}$ ]] || die "Invalid MLD_USER '$MLD_USER'"
}

# Files reach the guest through a bind mount at /mnt, so nothing depends on
# proot-distro's internal storage layout.
guest_root() { proot-distro login "$MLD_DISTRO" --shared-tmp --bind "${MLD_HOME}:/mnt" -- "$@"; }
guest_user() { proot-distro login "$MLD_DISTRO" --user "$MLD_USER" --shared-tmp --bind "${MLD_HOME}:/mnt" -- "$@"; }

net_check() { curl -fsS -m 15 -o /dev/null https://deb.debian.org; }

check_required_cmds() {
  local c missing=""
  for c in bash awk sed grep tail df stat mktemp tr date cp mv rm chmod mkdir find pkg; do
    have_cmd "$c" || missing="${missing} ${c}"
  done
  if [ -n "$missing" ]; then
    mld_hint "Install the missing tool(s) with 'pkg install <package>' (use 'pkg search <tool>' to find the package name)."
    die "Required commands missing in Termux:${missing}"
  fi
}

# ---- phase 1 ---------------------------------------------------------------
phase_checks() {
  local free ram arch
  ui_phase "Welcome and device checks" termux
  mld_is_termux || die "This installer must run inside Termux on Android."
  [ "$(id -u)" -ne 0 ] || die "Do not run as root."
  mld_require_supported_arch
  check_required_cmds
  arch="$(mld_arch)"
  ram="$(mld_ram_mb)"
  free="$(mld_free_mb "$PREFIX" || true)"
  log_ok "Termux detected, architecture: ${arch}"
  if [ "$arch" != aarch64 ]; then
    log_warn "ARM64 is the primary target. '${arch}' is less tested; some packages may be unavailable."
  fi
  if [ "$ram" -gt 0 ]; then
    log_info "RAM: ${ram} MB (device total from /proc/meminfo; Android may allow apps less)"
  else
    log_warn "RAM could not be detected - assuming a low-memory device."
  fi
  log_info "Profile: ${PROFILE} (override with --profile low|mid|high)"
  if [ -n "${free:-}" ]; then
    log_info "Free storage: ${free} MB (measured on Termux's own storage)"
    if [ "$free" -lt 3000 ]; then
      mld_hint "Free some space (3 GB minimum, 5 GB recommended), then re-run."
      die "Not enough free storage (${free} MB)."
    elif [ "$free" -lt 5000 ]; then
      log_warn "Less than 5 GB free; installation may be tight."
    fi
  else
    log_warn "Free storage could not be detected - make sure you have at least 3 GB."
  fi
  if have_cmd curl; then
    step_required "Checking network access (deb.debian.org)" net_check
  else
    log_info "curl is not installed yet; the network check runs after Termux packages are set up."
  fi
  if mld_distro_installed "$MLD_DISTRO"; then
    log_info "An existing Debian (PRoot) was found - it will be reused, not replaced."
  fi
  mld_confirm "Continue with the installation now?" y || die "Aborted by user."
}

# ---- phase 2 ---------------------------------------------------------------
phase_termux() {
  ui_phase "Termux dependencies" termux
  if have_cmd termux-wake-lock; then termux-wake-lock || true; fi
  step_required "Refreshing Termux package index" retry 3 3 pkg update -y
  interactive_required "Upgrading Termux packages (foreground; no spinner)" env DEBIAN_FRONTEND=noninteractive \
    apt-get -y -o Dpkg::Options::=--force-confold upgrade
  step_required "Installing proot-distro, curl, git, openssl" pkg install -y proot-distro curl git openssl
  have_cmd proot-distro || die "proot-distro is not available after installation."
  step_required "Checking network access (deb.debian.org)" net_check
  if ! curl -fsS -m 10 -o /dev/null -I https://github.com 2>/dev/null; then
    log_warn "github.com is not reachable: code-server (optional) cannot be downloaded right now."
  fi
}

# ---- phase 3 ---------------------------------------------------------------
sync_files() {
  [ "$REPO_ROOT" != "$MLD_HOME" ] || die "Run the installer from a checkout, not from $MLD_HOME"
  ( umask 077; mkdir -p "$MLD_HOME/status" )
  chmod 700 "$MLD_HOME"
  rm -rf "${MLD_HOME:?}/scripts" "${MLD_HOME:?}/configs"
  cp -R "$REPO_ROOT/scripts" "$REPO_ROOT/configs" "$MLD_HOME/"
  chmod -R go-rwx "$MLD_HOME"
  find "$MLD_HOME/scripts" -type f -name '*.sh' -exec chmod 700 {} +
  {
    printf 'MLD_DISTRO=%q\n' "$MLD_DISTRO"
    printf 'MLD_USER=%q\n' "$MLD_USER"
    printf 'MLD_PROFILE=%q\n' "$PROFILE"
    printf 'MLD_SRC=%q\n' "$REPO_ROOT"
  } >"$MLD_HOME/mld.env"
  chmod 600 "$MLD_HOME/mld.env"
}

check_guest_files() {
  guest_root bash -c '
    for f in scripts/lib/common.sh scripts/lib/ui.sh scripts/setup-vnc.sh scripts/ai-assistant.sh \
             scripts/guest/provision.sh scripts/guest/install-apps.sh scripts/guest/mld-code.sh \
             scripts/guest/verify.sh scripts/guest/browser-sandbox.sh \
             configs/vnc/xstartup configs/profiles/active.conf; do
      if [ ! -f "/opt/mld/$f" ]; then echo "missing in guest: /opt/mld/$f" >&2; exit 1; fi
    done'
}

phase_debian() {
  ui_phase "Debian PRoot setup" termux
  if mld_distro_installed "$MLD_DISTRO"; then
    log_info "Debian is already installed - reusing it (nothing is deleted or reset)."
  else
    step_required "Downloading and installing Debian (proot-distro)" retry 2 5 proot-distro install "$MLD_DISTRO"
  fi
  mld_distro_installed "$MLD_DISTRO" \
    || die "The Debian container was not created. Run 'proot-distro install debian' to see the error."
  step_required "Staging scripts and configs in ${MLD_HOME}" sync_files
  ui_env debian
  step_required "Checking that Debian starts" guest_root /bin/true
  step_required "Copying scripts into Debian (/opt/mld)" guest_root sh /mnt/scripts/guest/sync-in.sh "$PROFILE"
  step_required "Checking guest scripts exist" check_guest_files
  install_launcher
  ui_env debian
  : >"$MLD_HOME/status/provision.status"
  step_required "Provisioning base system (apt, locale, user '${MLD_USER}')" \
    guest_root env MLD_USER="$MLD_USER" MLD_PROFILE="$PROFILE" \
    MLD_STATUS_FILE=/mnt/status/provision.status bash /opt/mld/scripts/guest/provision.sh
  ui_read_status "$MLD_HOME/status/provision.status"
}

install_launcher() {
  ui_env termux
  cp "$REPO_ROOT/scripts/mld.sh" "$PREFIX/bin/mld"
  chmod 700 "$PREFIX/bin/mld"
  log_ok "Installed the 'mld' command"
}

# ---- phase 4 ---------------------------------------------------------------
ask_sandbox() {
  ui_env debian
  if [ "$WANT_NOSANDBOX" = yes ]; then
    log_warn "--allow-no-sandbox given: browser sandboxes will be disabled."
  else
    ui_note "Chromium and Firefox normally refuse to start inside PRoot because their security sandboxes need Linux features PRoot lacks. Disabling the sandbox makes browsers less safe. It is OFF by default and only used if you agree. You can change it later: mld browser-sandbox on|off"
    if mld_confirm_strict "Disable browser sandboxes so browsers can start?" n; then
      WANT_NOSANDBOX=yes
    else
      WANT_NOSANDBOX=no
    fi
  fi
  if [ "$WANT_NOSANDBOX" = yes ]; then
    step_required "Recording browser-sandbox choice (disabled)" \
      guest_root bash /opt/mld/scripts/guest/browser-sandbox.sh on --yes
  else
    step_required "Recording browser-sandbox choice (kept enabled)" \
      guest_root bash /opt/mld/scripts/guest/browser-sandbox.sh off
  fi
}

setup_desktop() {
  ui_env debian
  if [ -n "${MLD_VNC_PASSWORD:-}" ]; then
    ( umask 077; mkdir -p "$MLD_HOME/handoff"; printf '%s\n' "$MLD_VNC_PASSWORD" >"$MLD_HOME/handoff/vncpw" )
    unset MLD_VNC_PASSWORD
  fi
  ui_note "You will now choose a VNC password (6-8 characters). Input is hidden."
  interactive_required "Configuring VNC and the desktop for user '${MLD_USER}'" \
    guest_user env MLD_PROFILE="$PROFILE" bash /opt/mld/scripts/setup-vnc.sh setup
}

phase_desktop() {
  ui_phase "Desktop and VNC" debian
  ask_sandbox
  : >"$MLD_HOME/status/desktop.status"
  MLD_STEP_TIMEOUT="${MLD_DESKTOP_TIMEOUT:-0}" step_required "Installing XFCE4, TigerVNC and optional browsers" \
    guest_root env MLD_USER="$MLD_USER" MLD_STATUS_FILE=/mnt/status/desktop.status \
    bash /opt/mld/scripts/guest/install-apps.sh desktop
  ui_read_status "$MLD_HOME/status/desktop.status"
  setup_desktop
}

# ---- phase 5 ---------------------------------------------------------------
phase_devtools() {
  ui_phase "Development tools" debian
  : >"$MLD_HOME/status/devtools.status"
  MLD_STEP_TIMEOUT="${MLD_DEVTOOLS_TIMEOUT:-0}" step_required "Installing Node.js, Python, PHP, Git and code-server" \
    guest_root env MLD_USER="$MLD_USER" MLD_WITH_CODE_SERVER="$WITH_CODE_SERVER" \
    MLD_STATUS_FILE=/mnt/status/devtools.status bash /opt/mld/scripts/guest/install-apps.sh devtools
  ui_read_status "$MLD_HOME/status/devtools.status"
}

# ---- phase 6 ---------------------------------------------------------------
phase_ai() {
  local rc=0
  ui_phase "Optional AI helper" debian
  AI_STATE=skipped
  if [ "$WANT_AI" = ask ]; then
    ui_note "The AI helper sends your questions (and, for 'ai fix', the last lines of a command's output) to the AI provider you choose. That data leaves your phone and may cost money on your account. You need your own API key; it is stored only on this phone with file mode 600."
    if mld_confirm_strict "Set up the AI helper now?" n; then WANT_AI=yes; else WANT_AI=no; fi
  fi
  if [ "$WANT_AI" = yes ]; then
    run_interactive "Configuring the AI helper" \
      guest_user bash /opt/mld/scripts/ai-assistant.sh configure || rc=$?
    if [ "$rc" -eq 0 ]; then AI_STATE=configured; else AI_STATE=failed; fi
  else
    log_info "Skipped. Configure it later with: mld ai configure"
  fi
}

# ---- phase 7 ---------------------------------------------------------------
phase_theme() {
  local rc=0
  ui_phase "Optional Termux theme" termux
  THEME_STATE=skipped
  ui_note "The theme changes only the colours of the Termux terminal (file ~/.termux/colors.properties). It does NOT change the Android system theme, the XFCE desktop, or your VNC viewer app. Your existing file is backed up first (restore any time with: mld theme restore)."
  if [ "$WANT_THEME" = ask ]; then
    if mld_confirm_strict "Apply the MobileLinux Termux theme?" n; then WANT_THEME=yes; else WANT_THEME=no; fi
  fi
  if [ "$WANT_THEME" = yes ]; then
    bash "$MLD_HOME/scripts/setup-theme.sh" apply --yes || rc=$?
    if [ "$rc" -eq 0 ]; then THEME_STATE=applied; else THEME_STATE=failed; fi
  else
    log_info "Skipped. Apply it later with: mld theme apply"
  fi
}

# ---- phase 8 ---------------------------------------------------------------
verify_host() {
  if have_cmd proot-distro; then ui_result "proot-distro" ok "$(command -v proot-distro)"
  else ui_result "proot-distro" fail "not installed" "pkg install proot-distro"; fi
  if [ -x "$PREFIX/bin/mld" ]; then ui_result "mld command" ok "$PREFIX/bin/mld"
  else ui_result "mld command" fail "launcher missing" "re-run the installer"; fi
  if [ -f "$MLD_HOME/scripts/diagnose.sh" ] && [ -f "$MLD_HOME/scripts/setup-theme.sh" ]; then
    ui_result "host scripts" ok "$MLD_HOME/scripts"
  else
    ui_result "host scripts" fail "missing in $MLD_HOME/scripts" "re-run the installer"
  fi
  if mld_distro_installed "$MLD_DISTRO"; then ui_result "Debian (PRoot)" ok "accessible"
  else ui_result "Debian (PRoot)" fail "not accessible" "proot-distro install debian"; fi
}

verify_optional() {
  case "$THEME_STATE" in
    applied)
      if bash "$MLD_HOME/scripts/setup-theme.sh" status >/dev/null 2>&1; then
        ui_result "Termux theme" ok "applied (restore: mld theme restore)"
      else
        ui_result "Termux theme" warn "was requested but is not active" "mld theme apply"
      fi ;;
    failed) ui_result "Termux theme" warn "apply failed" "mld theme apply (see its message)" ;;
    *)      ui_result "Termux theme" skip "not applied" "mld theme apply" ;;
  esac
  case "$AI_STATE" in
    configured) ui_result "AI helper" ok "configured (data goes to your provider)" ;;
    failed)     ui_result "AI helper" warn "configuration failed" "mld ai configure" ;;
    *)          ui_result "AI helper" skip "not configured" "mld ai configure" ;;
  esac
}

phase_verify() {
  local nfail
  ui_phase "Final verification" termux
  : >"$MLD_HOME/status/verify.status"
  verify_host
  ui_env debian
  step_required "Checking installed components inside Debian" \
    guest_root env MLD_USER="$MLD_USER" MLD_WITH_CODE_SERVER="$WITH_CODE_SERVER" \
    MLD_STATUS_FILE=/mnt/status/verify.status bash /opt/mld/scripts/guest/verify.sh
  ui_env termux
  ui_read_status "$MLD_HOME/status/verify.status"
  verify_optional
  nfail="$(ui_count_state fail)"
  if [ "$nfail" -gt 0 ]; then
    ui_summary_results
    mld_hint "Required components are missing (listed above). Re-run the installer; run '${UI_DIAG_CMD}' if it repeats."
    MLD_LAST_ERROR="Verification failed: ${nfail} required component(s) missing - installation is NOT complete."
    exit 1
  fi
  if have_cmd termux-wake-unlock; then termux-wake-unlock || true; fi
  finish
}

finish() {
  ui_summary
  printf '\n  %sNext steps%s\n' "$C_BOLD" "$C_RESET" >&2
  ui_rule
  cat >&2 <<EOF
  1. Start the desktop (in Termux):
       ${C_BOLD}mld start${C_RESET}
  2. Open a VNC viewer app (RealVNC Viewer, bVNC, ...)
     and connect to:  ${C_BOLD}localhost:5901${C_RESET}
  3. Stop it when done:
       ${C_BOLD}mld stop${C_RESET}

  Diagnostics:    mld diagnose   (prints locally, uploads nothing)
  Theme:          mld theme apply | mld theme restore
  Everything:     mld help
  Install log:    ${MLD_LOG_FILE}

EOF
  ui_note "Reminders: VNC listens on this phone only (localhost). VNC password login does not encrypt traffic, so never expose the port to a network. Terminal appearance varies by terminal, font, screen width and Termux version."
}

refresh() {
  ui_logo
  ui_phase "Refreshing installed scripts" termux
  mld_distro_installed "$MLD_DISTRO" || die "Nothing to refresh - Debian is not installed."
  step_required "Staging scripts and configs" sync_files
  ui_env debian
  step_required "Copying scripts into Debian (/opt/mld)" guest_root sh /mnt/scripts/guest/sync-in.sh "$PROFILE"
  install_launcher
  step_required "Re-applying guest configs" \
    guest_root env MLD_USER="$MLD_USER" MLD_PROFILE="$PROFILE" MLD_CONFIGS_ONLY=1 \
    bash /opt/mld/scripts/guest/provision.sh
  log_ok "Refresh complete."
}

main() {
  parse_args "$@"
  mld_load_env_file "$REPO_ROOT/.env"
  mld_ui_init
  UI_ERROR_SCREEN=1
  mld_log_raw "---- install.sh v${MLD_VERSION} started ----"
  resolve_profile
  if [ "$REFRESH" = 1 ]; then
    UI_PHASE_TOTAL=1
    refresh
    return 0
  fi
  ui_welcome
  phase_checks
  phase_termux
  phase_debian
  phase_desktop
  phase_devtools
  phase_ai
  phase_theme
  phase_verify
}

main "$@"
