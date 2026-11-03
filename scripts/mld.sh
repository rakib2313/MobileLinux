#!/usr/bin/env bash
# =============================================================================
# mld - day-to-day control for MobileLinux (runs in Termux)
# Installed to $PREFIX/bin/mld by install.sh
# =============================================================================
set -Eeuo pipefail

MLD_HOME="${MLD_HOME:-$HOME/.mld}"
if [ -r "$MLD_HOME/mld.env" ]; then
  # shellcheck source=/dev/null
  . "$MLD_HOME/mld.env"
fi
: "${MLD_DISTRO:=debian}"
: "${MLD_USER:=dev}"
: "${MLD_SRC:=}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
RUN_DIR="$MLD_HOME/run"
PID_FILE="$RUN_DIR/desktop.pid"
LOG_FILE="$RUN_DIR/desktop.log"
VNC_PORT="${MLD_VNC_PORT:-5901}"

msg() { printf '\033[1;36m[mld]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[mld]\033[0m %s\n' "$*" >&2; }

guest()      { proot-distro login "$MLD_DISTRO" --user "$MLD_USER" --shared-tmp -- "$@"; }
guest_root() { proot-distro login "$MLD_DISTRO" --shared-tmp -- "$@"; }

need_install() {
  if [ ! -d "$MLD_HOME/scripts" ]; then
    err "MobileLinux is not installed (missing $MLD_HOME/scripts). Run the installer first."
    exit 1
  fi
}

is_running() {
  local pid
  [ -f "$PID_FILE" ] || return 1
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

port_open() {
  ( exec 3<>"/dev/tcp/127.0.0.1/${VNC_PORT}" ) 2>/dev/null
}

show_connect() {
  cat <<EOF

  Open a VNC viewer app and connect to:  localhost:${VNC_PORT}
  Use the VNC password you chose. Stop with: mld stop
  (The port is reachable from this phone only. VNC password login does not
   encrypt traffic - do not expose this port to a network.)

EOF
}

cmd_start() {
  need_install
  mkdir -p "$RUN_DIR"
  chmod 700 "$RUN_DIR"
  if is_running; then
    msg "Desktop is already running."
    show_connect
    return 0
  fi
  if command -v termux-wake-lock >/dev/null 2>&1; then termux-wake-lock || true; fi
  : >"$LOG_FILE"
  msg "Starting desktop (profile: ${MLD_PROFILE:-auto}) ..."
  nohup proot-distro login "$MLD_DISTRO" --user "$MLD_USER" --shared-tmp -- \
    bash /opt/mld/scripts/setup-vnc.sh run >>"$LOG_FILE" 2>&1 </dev/null &
  echo $! >"$PID_FILE"
  disown "$!" 2>/dev/null || true
  local i
  for i in $(seq 1 60); do
    if port_open; then
      msg "Desktop is up."
      show_connect
      return 0
    fi
    if ! is_running; then break; fi
    sleep 0.5
  done
  err "The desktop did not start. Last log lines:"
  tail -n 20 "$LOG_FILE" >&2 || true
  err "Run 'mld diagnose' for a local report (nothing is uploaded)."
  cmd_stop >/dev/null 2>&1 || true
  return 1
}

cmd_stop() {
  local pid
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then kill "$pid" 2>/dev/null || true; fi
    rm -f "$PID_FILE"
  fi
  sleep 1
  if command -v pkill >/dev/null 2>&1; then
    pkill -f 'setup-vnc.sh run' 2>/dev/null || true
    pkill -x Xtigervnc 2>/dev/null || true
  fi
  rm -f "$PREFIX/tmp/.X1-lock" "$PREFIX/tmp/.X11-unix/X1" 2>/dev/null || true
  if command -v termux-wake-unlock >/dev/null 2>&1; then termux-wake-unlock || true; fi
  msg "Desktop stopped."
}

cmd_status() {
  if is_running && port_open; then
    msg "Desktop: RUNNING  (connect to localhost:${VNC_PORT})"
  elif is_running; then
    msg "Desktop: STARTING (process alive, port not open yet)"
  else
    msg "Desktop: stopped"
  fi
}

cmd_update() {
  [ -n "$MLD_SRC" ] && [ -d "$MLD_SRC/.git" ] || { err "No git checkout recorded; clone the repository again and re-run its installer."; return 1; }
  git -C "$MLD_SRC" pull --ff-only
  bash "$MLD_SRC/scripts/install.sh" --refresh
}

cmd_autostart() {
  local boot="$HOME/.termux/boot/mld-start.sh"
  case "${1:-}" in
    on)
      mkdir -p "$(dirname "$boot")"
      printf '#!/data/data/com.termux/files/usr/bin/sh\ntermux-wake-lock\nmld start\n' >"$boot"
      chmod 700 "$boot"
      msg "Autostart enabled (requires the Termux:Boot app)." ;;
    off)
      rm -f "$boot"
      msg "Autostart disabled." ;;
    *) err "Usage: mld autostart on|off"; return 1 ;;
  esac
}

cmd_log() {
  local f="${MLD_LOG_FILE:-$HOME/.cache/mld/mld.log}"
  msg "Installer/tool log: $f"
  if [ -f "$f" ]; then tail -n "${1:-40}" "$f"; else err "No log file yet."; fi
}

cmd_help() {
  cat <<'EOF'
mld - MobileLinux control

  mld start              Start the desktop (VNC on localhost:5901)
  mld stop               Stop the desktop
  mld restart            Stop, then start
  mld status             Show whether the desktop is running
  mld passwd             Change the VNC password
  mld resolution WxH     Set screen size, e.g. 1280x720 (restart afterwards)
  mld shell              Open a terminal in the Linux environment (user)
  mld root               Open a root shell in the Linux environment
  mld ai [args]          AI coding helper (configure | ask | chat | fix | status)
  mld code-password      Print the code-server login password
  mld browser-sandbox on|off|status
                         Browser sandbox choice (on = sandbox DISABLED, risky)
  mld theme apply|restore|status|backups
                         Optional Termux colour theme (with backup/restore)
  mld diagnose [--log] [--save] [--no-guest]
                         Local, non-sensitive diagnostics (nothing is uploaded)
  mld log [N]            Show the last N lines of the log (default 40)
  mld autostart on|off   Start the desktop when the phone boots (Termux:Boot)
  mld update             Pull the latest version and re-apply configs
  mld uninstall          Remove what this project installed
  mld version            Print version info
EOF
}

main() {
  local cmd="${1:-help}"
  if [ $# -gt 0 ]; then shift; fi
  case "$cmd" in
    start)         cmd_start ;;
    stop)          cmd_stop ;;
    restart)       cmd_stop; cmd_start ;;
    status)        cmd_status ;;
    passwd)        need_install; guest bash /opt/mld/scripts/setup-vnc.sh passwd ;;
    resolution)    need_install; guest bash /opt/mld/scripts/setup-vnc.sh resolution "${1:-}" ;;
    shell)         proot-distro login "$MLD_DISTRO" --user "$MLD_USER" --shared-tmp ;;
    root)          proot-distro login "$MLD_DISTRO" --shared-tmp ;;
    ai)            need_install; guest bash /opt/mld/scripts/ai-assistant.sh "$@" ;;
    code-password) need_install; guest bash /opt/mld/scripts/guest/mld-code.sh --show-password ;;
    browser-sandbox) need_install; guest_root bash /opt/mld/scripts/guest/browser-sandbox.sh "${1:-status}" "${2:-}" ;;
    theme)         need_install; bash "$MLD_HOME/scripts/setup-theme.sh" "${1:-status}" "${@:2}" ;;
    diagnose|doctor) need_install; bash "$MLD_HOME/scripts/diagnose.sh" "$@" ;;
    log)           cmd_log "${1:-40}" ;;
    autostart)     cmd_autostart "${1:-}" ;;
    update)        cmd_update ;;
    uninstall)     need_install; bash "$MLD_HOME/scripts/uninstall.sh" "$@" ;;
    version|-v|--version) echo "MobileLinux 2.0.0 (command: mld)" ;;
    help|-h|--help) cmd_help ;;
    *) err "Unknown command: $cmd"; cmd_help; exit 1 ;;
  esac
}

main "$@"
