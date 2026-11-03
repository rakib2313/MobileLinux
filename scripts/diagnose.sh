#!/usr/bin/env bash
# =============================================================================
# diagnose.sh - local, non-sensitive diagnostics for MobileLinux (runs in Termux)
#   bash scripts/diagnose.sh [--log] [--save] [--no-guest]      (or: mld diagnose)
#   --log        also show the last 40 log lines (secrets are masked)
#   --save       also write the report to ~/mld-diagnostics-<time>.txt (mode 600)
#   --no-guest   skip the checks inside Debian (faster)
# Nothing is collected or uploaded automatically. Read the output yourself and
# remove anything private before sharing it.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
MLD_HOME="${MLD_HOME:-$HOME/.mld}"
MLD_DISTRO=debian
MLD_USER=dev
if [ -r "$MLD_HOME/mld.env" ]; then
  # shellcheck source=/dev/null
  . "$MLD_HOME/mld.env"
fi
SHOW_LOG=0
SAVE=0
GUEST=1
for a in "$@"; do
  case "$a" in
    --log) SHOW_LOG=1 ;;
    --save) SAVE=1 ;;
    --no-guest) GUEST=0 ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown option: $a" >&2; exit 1 ;;
  esac
done

sec() { printf '\n== %s ==\n' "$1"; }
kv()  { printf '  %-22s %s\n' "$1" "$2"; }
yn()  { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }

report() {
  local c v free ram prop
  printf 'MobileLinux diagnostics v%s - %s\n' "$MLD_VERSION" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf 'Printed locally only. Review before sharing; remove anything private.\n'

  sec "Environment"
  kv "Termux detected" "$(yn mld_is_termux)"
  kv "TERMUX_VERSION" "${TERMUX_VERSION:-<unset>}"
  if have_cmd getprop; then
    for prop in ro.build.version.release ro.build.version.sdk ro.product.model; do
      kv "$prop" "$(getprop "$prop" 2>/dev/null || echo '?')"
    done
  fi
  kv "Architecture" "$(uname -m) -> $(mld_arch)"
  kv "Kernel" "$(uname -sr)"
  kv "Bash" "${BASH_VERSION:-?}"
  ram="$(mld_ram_mb)"
  if [ "$ram" -gt 0 ]; then kv "RAM total" "${ram} MB (device total; apps may get less)"; else kv "RAM total" "unknown (/proc/meminfo unreadable)"; fi
  free="$(mld_free_mb "${PREFIX}" || true)"
  if [ -n "$free" ]; then kv "Free storage" "${free} MB (Termux storage)"; else kv "Free storage" "unknown (df could not read it)"; fi
  kv "TERM / COLUMNS" "${TERM:-?} / ${COLUMNS:-$(tput cols 2>/dev/null || echo '?')}"
  kv "NO_COLOR set" "$([ -n "${NO_COLOR:-}" ] && echo yes || echo no)"
  kv "Locale" "${LC_ALL:-${LANG:-<unset>}}"

  sec "Host commands (Termux)"
  for c in bash curl git openssl awk sed grep pkg proot-distro termux-wake-lock termux-reload-settings python3; do
    v="missing"
    if have_cmd "$c"; then v="ok"; fi
    kv "$c" "$v"
  done

  sec "PRoot-Distro / Debian"
  if have_cmd dpkg-query; then
    kv "proot-distro version" "$(dpkg-query -W -f='${Version}' proot-distro 2>/dev/null || echo 'not installed')"
  fi
  kv "Debian installed" "$(yn mld_distro_installed "$MLD_DISTRO")"

  sec "MobileLinux install"
  kv "Install dir" "$MLD_HOME ($([ -d "$MLD_HOME" ] && echo present || echo missing))"
  kv "mld command" "$([ -x "$PREFIX/bin/mld" ] && echo present || echo missing)"
  kv "Profile / user" "${MLD_PROFILE:-?} / ${MLD_USER}"
  kv "Scripts staged" "$([ -f "$MLD_HOME/scripts/install.sh" ] && echo yes || echo no)"

  sec "Desktop / VNC (host view)"
  local pid=""
  [ -f "$MLD_HOME/run/desktop.pid" ] && pid="$(cat "$MLD_HOME/run/desktop.pid" 2>/dev/null)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then kv "Launcher process" "running"; else kv "Launcher process" "not running"; fi
  kv "Port ${MLD_VNC_PORT:-5901} open" "$( ( exec 3<>"/dev/tcp/127.0.0.1/${MLD_VNC_PORT:-5901}" ) 2>/dev/null && echo yes || echo no)"

  sec "Termux theme"
  if [ -f "$MLD_HOME/scripts/setup-theme.sh" ]; then
    if bash "$MLD_HOME/scripts/setup-theme.sh" status >/dev/null 2>&1; then kv "MobileLinux theme" "applied"; else kv "MobileLinux theme" "not applied"; fi
  fi

  if [ "$GUEST" = 1 ] && have_cmd proot-distro && mld_distro_installed "$MLD_DISTRO" && [ -f "$MLD_HOME/scripts/guest/verify.sh" ]; then
    sec "Inside Debian (component checks)"
    local sf="$MLD_HOME/status/diagnose.status" tag name state note fix
    mkdir -p "$MLD_HOME/status"
    : >"$sf"
    timeout -k 5 180 proot-distro login "$MLD_DISTRO" --shared-tmp --bind "${MLD_HOME}:/mnt" -- \
      env MLD_USER="$MLD_USER" MLD_STATUS_FILE=/mnt/status/diagnose.status \
      bash /opt/mld/scripts/guest/verify.sh >/dev/null 2>&1
    kv "verify.sh exit code" "$?"
    while IFS='|' read -r tag name state note fix; do
      if [ "$tag" = STATUS ]; then printf '  %-5s %-22s %s\n' "$state" "$name" "$note"; fi
    done <"$sf"
  elif [ "$GUEST" = 1 ]; then
    sec "Inside Debian"
    kv "skipped" "Debian or guest scripts not available"
  fi

  sec "Log file"
  kv "Path" "$MLD_LOG_FILE"
  if [ -f "$MLD_LOG_FILE" ]; then
    kv "Size (bytes)" "$(mld_file_size "$MLD_LOG_FILE")"
    kv "Permissions" "$(stat -c '%a' "$MLD_LOG_FILE" 2>/dev/null || echo '?')"
    if [ "$SHOW_LOG" = 1 ]; then
      printf '  --- last 40 lines (secrets masked) ---\n'
      tail -n 40 "$MLD_LOG_FILE" | mld_redact | sed 's/^/  | /'
    else
      kv "Tip" "add --log to include the last 40 lines"
    fi
  else
    kv "Status" "no log file yet"
  fi
  printf '\nEnd of report. Nothing was uploaded.\n'
}

if [ "$SAVE" = 1 ]; then
  out="$HOME/mld-diagnostics-$(date '+%Y%m%d-%H%M%S').txt"
  ( umask 077; report 2>&1 | mld_redact | tee "$out" )
  chmod 600 "$out" 2>/dev/null || true
  printf '\nSaved to %s (mode 600). Review it before sharing.\n' "$out"
else
  report 2>&1 | mld_redact
fi
