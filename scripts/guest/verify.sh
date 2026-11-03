#!/usr/bin/env bash
# =============================================================================
# verify.sh - checks what is ACTUALLY installed in the Debian guest (runs as root)
# Writes STATUS lines to $MLD_STATUS_FILE; always exits 0 unless it cannot run.
#   ok = fine | fail = REQUIRED part missing | warn = optional part missing
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
mld_enable_traps

MLD_USER="${MLD_USER:-dev}"
MLD_WITH_CODE_SERVER="${MLD_WITH_CODE_SERVER:-1}"
HOME_DIR="/home/${MLD_USER}"

req_cmd() { # label command [fix]
  if have_cmd "$2"; then
    mld_status "$1" ok "$(command -v "$2")"
    log_ok "$1"
  else
    mld_status "$1" fail "command '$2' not found" "${3:-re-run the installer}"
    log_err "$1 missing"
  fi
}

req_file() { # label path test(-f|-x|-d) [fix]
  if [ "$3" "$2" ]; then
    mld_status "$1" ok "$2"
    log_ok "$1"
  else
    mld_status "$1" fail "missing: $2" "${4:-re-run the installer}"
    log_err "$1 missing"
  fi
}

[ -f /etc/debian_version ] || die "verify.sh must run inside the Debian guest."
mld_status "Debian guest" ok "Debian $(cat /etc/debian_version)"

for c in startxfce4 xfce4-session xfwm4 xfce4-panel; do req_cmd "XFCE: $c" "$c"; done
req_cmd "TigerVNC server (Xtigervnc)" Xtigervnc
if have_cmd tigervncpasswd; then
  req_cmd "TigerVNC password tool" tigervncpasswd
else
  req_cmd "TigerVNC password tool" vncpasswd "install tigervnc-tools inside Debian"
fi
req_cmd "dbus-launch" dbus-launch
req_cmd "xauth" xauth
req_cmd "openssl" openssl
req_cmd "Node.js" node
req_cmd "npm" npm
req_cmd "Python 3" python3
req_cmd "pip" pip3
req_cmd "Git" git
req_cmd "PHP CLI" php

req_file "guest scripts" /opt/mld/scripts/setup-vnc.sh -f
req_file "VNC startup file (xstartup)" "$HOME_DIR/.vnc/xstartup" -x "run setup-vnc.sh setup (installer phase 4)"
req_file "VNC password file" "$HOME_DIR/.vnc/passwd" -f "mld passwd"

nb=0
for b in chromium firefox-esr; do
  if have_cmd "$b"; then
    nb=$((nb + 1))
    mld_status "Browser: $b" ok "$(command -v "$b")"
  else
    mld_status "Browser: $b" warn "not installed" "in Debian: apt-get install $b"
  fi
done
if [ "$nb" -eq 0 ]; then
  mld_status "At least one browser" fail "neither chromium nor firefox-esr is installed" "mld root, then: apt-get install firefox-esr"
fi

if have_cmd code-server; then
  mld_status "code-server" ok "$(code-server --version 2>/dev/null | head -n1 || echo installed)"
elif [ "$MLD_WITH_CODE_SERVER" = "1" ]; then
  mld_status "code-server" warn "not installed" "re-run the installer when github.com is reachable"
else
  mld_status "code-server" skip "disabled by option" "re-run without --no-code-server"
fi

nosb=0
if [ -r /etc/mld/browser.conf ]; then
  # shellcheck source=/dev/null
  . /etc/mld/browser.conf
  nosb="${MLD_BROWSER_NOSANDBOX:-0}"
fi
if [ "$nosb" = "1" ]; then
  mld_status "Browser sandbox" warn "DISABLED (your choice; risky)" "mld browser-sandbox off"
else
  mld_status "Browser sandbox" ok "enabled (browsers may fail to start in PRoot; see README)"
fi
log_ok "Verification finished (see statuses)"
