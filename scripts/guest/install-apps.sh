#!/usr/bin/env bash
# =============================================================================
# install-apps.sh - desktop + developer software (runs as root in the guest)
#   install-apps.sh desktop    XFCE4 (minimal), TigerVNC (required); Chromium and
#                              Firefox ESR (each optional, reported separately)
#   install-apps.sh devtools   Node.js, npm, Python 3, PHP CLI, Git (required);
#                              code-server + extensions (optional)
#   install-apps.sh all        both
# Required failures stop the script. Optional failures are written to
# $MLD_STATUS_FILE (STATUS|name|state|note|fix) and the script carries on.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
mld_enable_traps

exec </dev/null
mld_noninteractive_env
OPT=/opt/mld
MLD_USER="${MLD_USER:-dev}"
MLD_WITH_CODE_SERVER="${MLD_WITH_CODE_SERVER:-1}"
CODE_SERVER_FALLBACK_VERSION="4.96.4"

[ "$(id -u)" -eq 0 ] || die "install-apps.sh must run as root inside the Debian guest."
[ -f /etc/debian_version ] || die "This script must run inside the Debian guest."
[[ "$MLD_USER" =~ ^[a-z][a-z0-9_-]{0,30}$ ]] || die "Invalid user name: $MLD_USER"
id "$MLD_USER" >/dev/null 2>&1 || die "User '$MLD_USER' does not exist - the base provisioning step did not finish."

DESKTOP_PKGS=(
  xfce4-session xfwm4 xfce4-panel xfdesktop4 xfce4-settings xfce4-appfinder
  xfce4-terminal xfce4-taskmanager thunar mousepad
  tigervnc-standalone-server tigervnc-common tigervnc-tools
  adwaita-icon-theme hicolor-icon-theme fonts-dejavu-core fonts-liberation
  at-spi2-core libglib2.0-bin desktop-file-utils shared-mime-info
)
DEV_PKGS=(
  nodejs npm python3 python3-pip python3-venv git curl wget
  php-cli php-mbstring php-xml php-curl
)

apt_install() { mld_apt install -y --no-install-recommends "$@"; }

install_desktop() {
  log_step "Installing XFCE4 + TigerVNC (required)"
  retry 3 5 mld_apt update
  retry 3 5 apt_install "${DESKTOP_PKGS[@]}"
  log_step "Installing browsers (optional, one by one)"
  local b
  for b in chromium firefox-esr; do
    if retry 3 5 apt_install "$b"; then
      log_ok "Installed $b"
    else
      log_warn "Could not install $b (optional)."
      mld_status "$b" warn "install failed" "in Debian (mld root): apt-get install $b"
    fi
  done
  configure_firefox
}

install_devtools() {
  log_step "Installing Node.js, Python, PHP, Git (required)"
  retry 3 5 mld_apt update
  retry 3 5 apt_install "${DEV_PKGS[@]}"
  if [ "$MLD_WITH_CODE_SERVER" = "1" ]; then
    log_step "Installing code-server (optional)"
    if install_code_server; then
      install_extensions || true
    fi
  else
    mld_status code-server skip "disabled with --no-code-server" "re-run the installer without --no-code-server"
  fi
}

configure_firefox() {
  if [ -d /usr/lib/firefox-esr ]; then
    mkdir -p /usr/lib/firefox-esr/distribution
    cat >/usr/lib/firefox-esr/distribution/policies.json <<'EOF'
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DontCheckDefaultBrowser": true,
    "NoDefaultBookmarks": true,
    "OverrideFirstRunPage": "",
    "Preferences": {
      "browser.cache.memory.capacity": { "Value": 65536, "Status": "default" },
      "browser.sessionstore.interval": { "Value": 60000, "Status": "default" },
      "layers.acceleration.disabled": { "Value": true, "Status": "default" },
      "media.ffmpeg.vaapi.enabled": { "Value": false, "Status": "default" },
      "dom.ipc.processCount": { "Value": 2, "Status": "default" }
    }
  }
}
EOF
    log_ok "Firefox tuned for low memory"
  fi
}

# Returns non-zero on any failure (the caller treats code-server as optional).
install_code_server() {
  local arch ver url deb
  arch="$(mld_deb_arch)"
  if have_cmd code-server; then
    log_info "code-server already installed."
    return 0
  fi
  case "$arch" in
    amd64|arm64) ;;
    *)
      log_warn "code-server has no official build for '$arch' - skipping."
      mld_status code-server skip "no official build for $arch" "use Mousepad or another editor"
      return 1 ;;
  esac
  ver="${MLD_CODE_SERVER_VERSION:-}"
  if [ -z "$ver" ]; then
    ver="$(curl -fsSL -m 20 https://api.github.com/repos/coder/code-server/releases/latest 2>/dev/null \
          | sed -n 's/.*"tag_name": *"v\{0,1\}\([0-9][0-9.]*\)".*/\1/p' | head -n1 || true)"
  fi
  if [ -z "$ver" ]; then
    ver="$CODE_SERVER_FALLBACK_VERSION"
    log_warn "Could not query the latest release; trying fallback version ${ver}."
  fi
  url="https://github.com/coder/code-server/releases/download/v${ver}/code-server_${ver}_${arch}.deb"
  deb="/tmp/code-server_${ver}_${arch}.deb"
  log_info "Downloading code-server ${ver} (${arch}) over HTTPS from GitHub releases"
  if ! retry 3 5 curl -fL --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 3600 -o "$deb" "$url"; then
    log_warn "code-server download failed."
    mld_status code-server warn "download failed" "re-run the installer when github.com is reachable"
    rm -f "$deb"
    return 1
  fi
  log_info "SHA-256 of the download: $(sha256sum "$deb" | cut -d' ' -f1) (not verified against a publisher checksum)"
  if ! apt_install "$deb"; then
    log_warn "code-server package could not be installed."
    mld_status code-server warn "package install failed" "re-run the installer"
    rm -f "$deb"
    return 1
  fi
  rm -f "$deb"
  log_ok "code-server ${ver} installed"
}

install_extensions() {
  local list="$OPT/configs/vscode/extensions.txt" ext ok=0 bad=0
  have_cmd code-server || return 0
  [ -r "$list" ] || return 0
  while IFS= read -r ext || [ -n "$ext" ]; do
    case "$ext" in
      ''|'#'*) continue ;;
    esac
    if ! [[ "$ext" =~ ^[A-Za-z0-9._-]+$ ]]; then
      log_warn "Skipping invalid extension id in list."
      continue
    fi
    if timeout -k 10 300 runuser -l "$MLD_USER" -c "code-server --install-extension '$ext'" >/dev/null 2>&1; then
      ok=$((ok + 1))
      log_ok "Extension installed: $ext"
    else
      bad=$((bad + 1))
      log_warn "Optional extension unavailable right now: $ext"
    fi
  done <"$list"
  if [ "$bad" -gt 0 ]; then
    mld_status "vscode-extensions" warn "${ok} installed, ${bad} failed" "mld shell, then: code-server --install-extension <id>"
  else
    mld_status "vscode-extensions" ok "${ok} installed"
  fi
}

cleanup() {
  apt-get clean
  rm -rf /tmp/*.deb
}

main() {
  local stage="${1:-all}"
  log_step "Installing applications (stage: ${stage}, arch: $(mld_deb_arch))"
  mld_apt_recover
  case "$stage" in
    desktop)  install_desktop ;;
    devtools) install_devtools ;;
    all)      install_desktop; install_devtools ;;
    *) die "Unknown stage '$stage' (use desktop, devtools or all)" ;;
  esac
  cleanup
  log_ok "Stage '${stage}' finished"
}

main "$@"
