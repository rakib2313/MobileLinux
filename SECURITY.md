# Security policy

MobileLinux is a hobby/educational Linux **userspace** running in Termux with PRoot. It has not been
security-audited and must not be described as "secure", "hardened" or "production-ready".

## Reporting a vulnerability

Please do not post exploit details in a public issue. Use GitHub's private reporting if it is enabled
for this repository: <https://github.com/rakib2313/MobileLinux/security/advisories/new>. If that page is
unavailable, open a public issue at <https://github.com/rakib2313/MobileLinux/issues> that says you have a
security report *without* technical details, and ask for a private channel. No private e-mail address is published.

## Secrets

* Never commit API keys, VNC passwords, code-server passwords or tokens. `.gitignore` excludes common
  secret files, but you are responsible for checking `git status` before every commit.
* The VNC password lives only in the guest at `~/.vnc/passwd` (mode 600), created by the VNC tool. Scripts never print it.
* `~/.config/mobilelinux/` is created with mode 700 and `config.env` with mode 600. Keep `ai.env` at 600.
* `scripts/ai-assistant.sh` passes the key to curl through a file descriptor (not on the command line) and
  redacts it from error output. Prompts and piped data **leave your device** and may be billed.
* If a secret was ever committed, revoke/rotate it; deleting the commit later is not enough.

## PRoot is not a strong sandbox

PRoot runs Linux programs in userspace on the **Android kernel**. It is a compatibility layer, not a security
boundary comparable to a VM. "root" inside the guest is not Android root, but guest programs run as your Termux
app user and can reach whatever Termux can reach (Termux files, network, shared storage if granted). Treat
anything you run in the guest as having the same trust level as Termux itself. Do not run untrusted software.
The desktop user created by the installer is unprivileged mainly to limit accidents.

## Local services and network exposure

* VNC is started with `-localhost yes`: it binds to loopback only. `setup-vnc.sh status` warns if it sees otherwise.
* Other apps on the same phone can still connect to loopback ports; the VNC password is the only barrier.
* code-server (optional) defaults to `127.0.0.1:8080` with password auth. Do not change it to `0.0.0.0` without TLS and a reason.
* Development servers: bind them to `127.0.0.1` (for example `python3 -m http.server 8000 --bind 127.0.0.1`).

## VNC transport security

VNC password authentication proves who you are but **does not encrypt** the session (and only the first 8
password characters count). Keeping the server on loopback avoids exposing it. If you ever need remote access,
tunnel it through SSH (or another encrypted tunnel) and keep the VNC port closed to the network.

## Browsers

Chromium and Firefox use OS sandboxes that frequently fail under PRoot. MobileLinux never disables a sandbox
automatically. `--no-sandbox` for Chromium is available only by explicit opt-in
(`MOBILELINUX_CHROMIUM_NO_SANDBOX=1`) and weakens protection against malicious web pages. Prefer the Android
browser for general browsing and for opening local servers.

## Supply chain

Packages come from Termux repositories, proot-distro and Debian apt. Optional code-server installs through npm,
which verifies package integrity. This project does not download or run unsigned scripts as root and does not
ship checksums it cannot verify. Always read scripts before running them (`less scripts/install.sh`).
