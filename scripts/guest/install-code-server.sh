#!/usr/bin/env bash
# Optional: install code-server with npm into ~/.local. RUN IN: Debian guest, as the desktop user.
#
# No binary release is downloaded by this script: npm fetches the package from the npm registry and
# verifies the integrity of what it downloads itself. Compatibility with the Debian-packaged Node.js
# is NOT guaranteed (code-server declares supported Node versions) and was not tested on a real device.
# code-server listens on 127.0.0.1:8080 by default with password authentication and generates its own
# password in ~/.config/code-server/config.yaml on first run. Do not bind it to 0.0.0.0 without TLS.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
ml_install_traps

[[ "$(id -u)" -ne 0 ]] || ml_die "Run as the normal desktop user, not root."
ml_require node npm
ml_info "Node.js $(node --version), npm $(npm --version). Installing code-server to \$HOME/.local (this compiles native modules and can take a long time)."
if ! npm install -g --prefix "$HOME/.local" code-server; then
  ml_err "code-server installation failed."
  ml_info "Likely causes: Node.js version not supported by the current code-server, missing build tools (re-run install-apps.sh --code-server as root), or low memory."
  ml_info "Alternative: use the Android browser with simpler tools, or see the code-server install docs for supported methods."
  exit 1
fi
ml_ok "Installed. Start it with:  \$HOME/.local/bin/code-server"
ml_info "Then open  http://127.0.0.1:8080  in the ANDROID browser. The password is in ~/.config/code-server/config.yaml (keep that file private)."
