#!/usr/bin/env bash
# Development tools and optional apps. RUN IN: Debian guest, as root (called by scripts/install.sh).
# Usage: install-apps.sh [--browser auto|none|chromium|firefox] [--skip-dev] [--code-server]
# Packages come from Debian's repositories; their versions may be older than upstream releases.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
ml_install_traps

BROWSER="auto" SKIP_DEV=0 CODE_SERVER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --browser) [[ $# -ge 2 ]] || ml_die "--browser needs a value" 2; BROWSER="$2"; shift 2 ;;
    --skip-dev) SKIP_DEV=1; shift ;;
    --code-server) CODE_SERVER=1; shift ;;
    *) ml_die "Unknown option: $1" 2 ;;
  esac
done
case "$BROWSER" in auto|none|chromium|firefox) ;; *) ml_die "Invalid --browser value: $BROWSER" 2 ;; esac

[[ "$(id -u)" -eq 0 ]] || ml_die "install-apps.sh must run as root inside the Debian guest."
ml_require apt-get apt-cache
ml_load_config
ml_resolve_profile
ml_load_profile "$ML_PROFILE_RESOLVED"
if [[ "$BROWSER" == auto ]]; then
  BROWSER="$ML_BROWSER_DEFAULT"
fi
export DEBIAN_FRONTEND=noninteractive
problems=0

apt-get update || ml_die "apt-get update failed. Check the network."

if ((SKIP_DEV == 0)); then
  ml_step "Core development tools (Debian packages)"
  core=(git curl wget ca-certificates python3 nodejs npm)
  for pkg in "${core[@]}"; do
    ml_apt_available "$pkg" || ml_die "Required package '$pkg' is not available in this Debian guest."
  done
  apt-get install -y --no-install-recommends "${core[@]}" \
    || ml_die "Could not install core development tools."
  ml_apt_install_optional python3-pip python3-venv jq unzip zip nano less rsync openssh-client
  ml_info "Versions installed (Debian packages can be older than upstream):"
  for v in "git --version" "python3 --version" "node --version" "npm --version"; do
    $v 2>/dev/null | sed 's/^/    /' || true
  done
fi

install_chromium() {
  if ! ml_apt_available chromium; then
    ml_warn "Debian package 'chromium' is not available for this release/architecture. Use the Android browser (see README) or try --browser firefox."
    return 1
  fi
  apt-get install -y --no-install-recommends chromium || { ml_warn "Chromium failed to install."; return 1; }
  install -m 0755 "$SCRIPT_DIR/mobilelinux-chromium" /usr/local/bin/mobilelinux-chromium
  install -d -m 755 /etc/mobilelinux
  if [[ ! -e /etc/mobilelinux/chromium-flags.conf ]]; then
    install -m 0644 "$ML_ROOT/configs/chromium/flags.conf" /etc/mobilelinux/chromium-flags.conf
  fi
  install -d -m 755 /usr/local/share/applications
  cat >/usr/local/share/applications/mobilelinux-chromium.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Chromium (MobileLinux)
Comment=Chromium with conservative PRoot-friendly flags (sandbox stays enabled)
Exec=/usr/local/bin/mobilelinux-chromium %U
Icon=chromium
Terminal=false
Categories=Network;WebBrowser;
DESKTOP
  ml_ok "Chromium installed. Launch with: mobilelinux-chromium"
  ml_warn "Chromium's sandbox may not work under PRoot and the browser may crash on start. If so, prefer the Android browser."
  ml_warn "Running Chromium with --no-sandbox weakens security; it is only possible by explicit opt-in: MOBILELINUX_CHROMIUM_NO_SANDBOX=1 mobilelinux-chromium"
}

install_firefox() {
  if ! ml_apt_available firefox-esr; then
    ml_warn "Debian package 'firefox-esr' is not available for this release/architecture."
    return 1
  fi
  apt-get install -y --no-install-recommends firefox-esr || { ml_warn "Firefox ESR failed to install."; return 1; }
  ml_ok "Firefox ESR installed. Launch with: firefox-esr"
  ml_warn "Firefox's content sandbox may fail under PRoot. MobileLinux never disables it for you; see README before changing it."
}

case "$BROWSER" in
  none) ml_info "No browser requested. Use the Android browser to open local servers (e.g. http://127.0.0.1:8000)." ;;
  chromium) ml_step "Browser: Chromium (optional)"; install_chromium || problems=$((problems + 1)) ;;
  firefox) ml_step "Browser: Firefox ESR (optional)"; install_firefox || problems=$((problems + 1)) ;;
esac

if ((CODE_SERVER == 1)); then
  ml_step "Build tools for code-server (optional, large download)"
  ml_apt_install_optional build-essential pkg-config python3 make g++ libx11-dev libxkbfile-dev libsecret-1-dev libkrb5-dev
  ml_info "The code-server package itself is installed by install-code-server.sh as your normal user."
fi

if ((problems > 0)); then
  ml_warn "Finished with $problems optional problem(s); the desktop and core tools are unaffected."
  exit 1
fi
ml_ok "Apps step finished."
