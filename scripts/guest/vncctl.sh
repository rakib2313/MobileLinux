#!/usr/bin/env bash
# TigerVNC control. RUN IN: Debian guest as the desktop user (normally via scripts/setup-vnc.sh in Termux).
# Usage: vncctl.sh start|stop|restart|status|passwd
# Security: the server is started with "-localhost yes" (loopback only) and VNC password authentication.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
ml_install_traps

[[ "$(id -u)" -ne 0 ]] || ml_die "Do not run the VNC server as root. Use the desktop user."
ml_load_config
ml_resolve_profile
ml_load_profile "$ML_PROFILE_RESOLVED"

N="$ML_VNC_DISPLAY"
PORT=$((5900 + N))
VNC_DIR="$HOME/.vnc"
PASSFILE="$VNC_DIR/passwd"
LOCKFILE="/tmp/.X${N}-lock"
SOCKET="/tmp/.X11-unix/X${N}"

find_bin() { # find_bin name1 name2 ...
  local b
  for b in "$@"; do
    if ml_have "$b"; then command -v "$b"; return 0; fi
  done
  return 1
}

server_pid() { # pid recorded in the X lock file, if any
  [[ -r "$LOCKFILE" ]] || return 0
  tr -d ' \n' <"$LOCKFILE" 2>/dev/null || true
}

is_running() {
  local pid
  pid="$(server_pid)"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

# Remove ONLY runtime leftovers (lock/socket/pid files) of a server that is no longer alive.
clean_stale() {
  local pid f
  pid="$(server_pid)"
  if [[ -e "$LOCKFILE" || -e "$SOCKET" ]] && ! is_running; then
    ml_warn "Found stale X lock/socket for display :$N (pid '${pid:-unknown}' is not running); removing runtime files only."
    rm -f -- "$LOCKFILE" "$SOCKET" || ml_die "Could not remove $LOCKFILE / $SOCKET (owned by another user?). Remove them manually if no VNC server is running."
  fi
  for f in "$VNC_DIR"/*":$N.pid"; do
    [[ -e "$f" ]] || continue
    pid="$(tr -d ' \n' <"$f" 2>/dev/null || true)"
    if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
      ml_info "Removing stale pid file $f"
      rm -f -- "$f"
    fi
  done
}

cmd_passwd() {
  local tool
  tool="$(find_bin tigervncpasswd vncpasswd)" || ml_die "TigerVNC password tool not found. Re-run scripts/install.sh."
  install -d -m 700 "$VNC_DIR"
  ml_info "Choose a VNC password. Only the first 8 characters are used by VNC authentication."
  ml_info "Answer 'n' if asked about a view-only password. The password is stored hashed-style in $PASSFILE (mode 600); it is never printed."
  "$tool" "$PASSFILE"
  chmod 600 "$PASSFILE"
  ml_ok "Password saved. If the desktop is running, restart it: bash scripts/setup-vnc.sh restart"
}

cmd_start() {
  local bin i
  [[ -f "$PASSFILE" ]] || ml_die "No VNC password set yet. Run: bash scripts/setup-vnc.sh passwd"
  [[ -x "$VNC_DIR/xstartup" ]] || ml_die "$VNC_DIR/xstartup missing or not executable. Re-run scripts/install.sh."
  if is_running; then
    ml_ok "VNC server for display :$N is already running (port $PORT, localhost)."
    return 0
  fi
  clean_stale
  bin="$(find_bin tigervncserver vncserver)" || ml_die "TigerVNC server not found. Re-run scripts/install.sh."
  ml_info "Starting display :$N at ${ML_GEOMETRY}, depth ${ML_DEPTH} (profile $ML_PROFILE_RESOLVED), listening on localhost:$PORT only."
  if ! "$bin" ":$N" -localhost yes -geometry "$ML_GEOMETRY" -depth "$ML_DEPTH" \
      -xstartup "$VNC_DIR/xstartup" -SecurityTypes VncAuth -PasswordFile "$PASSFILE"; then
    ml_err "The VNC server failed to start. Look at the log: ls $VNC_DIR/*.log  (e.g. tail -n 30 $VNC_DIR/*:$N.log)"
    exit 1
  fi
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [[ -S "$SOCKET" ]] && is_running; then
      ml_ok "VNC is up. Connect a VNC client to localhost:$PORT"
      return 0
    fi
    sleep 1
  done
  ml_die "The server command returned but display :$N did not come up. Check the logs in $VNC_DIR/ ."
}

cmd_stop() {
  local bin pid
  bin="$(find_bin tigervncserver vncserver)" || ml_die "TigerVNC server not found."
  if ! is_running; then
    clean_stale
    ml_ok "VNC server for display :$N is not running."
    return 0
  fi
  pid="$(server_pid)"
  if "$bin" -kill ":$N"; then
    ml_ok "Stopped display :$N."
  else
    ml_err "Could not stop display :$N cleanly. Nothing was force-killed. If it is truly stuck, you may run: kill $pid"
    exit 1
  fi
}

cmd_status() {
  local pid listen
  if is_running; then
    pid="$(server_pid)"
    ml_ok "Running: display :$N, pid $pid"
    ps -o args= -p "$pid" 2>/dev/null | cut -c1-200 || true
    if ml_have ss; then
      listen="$(ss -ltn 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$" {print $4}' | paste -sd' ' -)"
      if [[ -z "$listen" ]]; then
        ml_warn "Could not see a listener on port $PORT (ss may be restricted on Android)."
      elif [[ "$listen" == *"127.0.0.1:$PORT"* || "$listen" == *"[::1]:$PORT"* ]] && [[ "$listen" != *"0.0.0.0"* && "$listen" != *"*:"* ]]; then
        ml_ok "Listening on loopback only: $listen"
      else
        ml_warn "Port $PORT is bound to: $listen  -- this may be reachable from other devices! Stop and restart via scripts/setup-vnc.sh."
      fi
    fi
  else
    ml_info "Not running (display :$N)."
    [[ -e "$LOCKFILE" ]] && ml_warn "A stale lock file exists; 'start' will clean it automatically."
  fi
  [[ -f "$PASSFILE" ]] && ml_info "Password file present." || ml_warn "No VNC password set yet (run: passwd)."
  return 0
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  restart) cmd_stop; cmd_start ;;
  status) cmd_status ;;
  passwd) cmd_passwd ;;
  *) ml_die "Usage: vncctl.sh start|stop|restart|status|passwd" 2 ;;
esac
