#!/usr/bin/env bash
# =============================================================================
# browser-sandbox.sh - opt in/out of disabling browser sandboxes (root, in guest)
#   browser-sandbox.sh on [--yes]   DISABLE sandboxes (needed for most PRoot setups; risky)
#   browser-sandbox.sh off          keep/restore sandboxes (browsers may not start)
#   browser-sandbox.sh status
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
mld_enable_traps

CONF=/etc/mld/browser.conf
[ "$(id -u)" -eq 0 ] || die "Run as root (use: mld browser-sandbox ...)."

write_conf() { # 0|1
  mkdir -p /etc/mld
  printf '# MLD_BROWSER_NOSANDBOX=1 disables browser sandboxes (risky). Default 0.\nMLD_BROWSER_NOSANDBOX=%s\n' "$1" >"$CONF"
  chmod 644 "$CONF"
}

current() {
  local v=0
  if [ -r "$CONF" ]; then
    v="$( . "$CONF"; printf '%s' "${MLD_BROWSER_NOSANDBOX:-0}" )"
  fi
  echo "$v"
}

case "${1:-status}" in
  on)
    log_warn "This DISABLES the Chromium and Firefox security sandboxes inside MobileLinux."
    log_warn "Malicious web pages would then have fewer barriers. Do not log in to banking or primary email here."
    if [ "${2:-}" != "--yes" ]; then
      mld_confirm_strict "Disable browser sandboxes?" n || { log_info "Unchanged."; exit 0; }
    fi
    write_conf 1
    log_ok "Browser sandboxes disabled. Restart the desktop: mld restart"
    ;;
  off)
    write_conf 0
    log_ok "Browser sandboxes kept enabled. Browsers may fail to start in PRoot; use 'mld browser-sandbox on' if you accept the risk."
    ;;
  status)
    if [ "$(current)" = 1 ]; then log_warn "Browser sandboxes: DISABLED (opt-in)"; else log_ok "Browser sandboxes: enabled"; fi
    ;;
  *) echo "Usage: browser-sandbox.sh on|off|status" >&2; exit 1 ;;
esac
