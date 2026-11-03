# Security Policy

MobileLinux is **not** a security sandbox. It is a convenience layer (Termux + PRoot) on top of
Android. It is unofficial and not affiliated with Linux, Debian, Termux or Android.

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Use GitHub's
*"Report a vulnerability"* (Security tab -> Advisories) on
https://github.com/rakib2313/MobileLinux. Include steps to reproduce, the affected version and
the impact. Never include passwords, API keys or tokens in a report.

## Secret-handling rules

| Rule | How it is done |
|------|----------------|
| No hardcoded secrets | Nothing in the repo contains passwords, tokens or API keys; CI greps for common token formats. |
| Runtime prompting | VNC and AI credentials are prompted with hidden input from the real terminal. |
| Templates only | `.env.example` documents settings; the real `.env` is git-ignored and set to mode `600`. |
| Safe parsing | `.env` is **parsed, never `source`d**; only `MLD_[A-Z0-9_]+` keys are accepted. |
| Strict permissions | `~/.mld` = `700`; `~/.vnc/passwd`, `ai.env`, code-server `config.yaml` and the log file = `600`. |
| Short-lived handoff | A non-interactive VNC password goes through a `0600` file that is deleted after one use - never through command-line arguments. |
| Logs | Passwords and keys are never written on purpose. Log lines shown on screen and diagnostics are passed through a masking filter, but **always read a log before sharing it**. |

If you commit a secret by accident: **revoke/rotate it immediately**, then purge the history.

## Design decisions and limits

* **VNC listens on `127.0.0.1` only.** VNC password authentication does **not** encrypt traffic and
  only uses the first 8 characters. Do not expose it; if you ever need remote access, tunnel it
  (SSH/VPN). `MLD_VNC_LAN=1` exists but is discouraged.
* **code-server binds to `127.0.0.1:8080` with password auth.** Other Android apps share the
  loopback interface, so the (random) password matters.
* **Browser sandboxes are ON by default.** PRoot has no user namespaces or seccomp support, so
  Chromium and Firefox often cannot start with their sandboxes. The installer asks you whether to
  disable them (default **no**); `--allow-no-sandbox` skips the question. Change it any time:
  `mld browser-sandbox on|off|status`. With sandboxes disabled, a malicious web page has fewer
  barriers: only use trusted sites and keep banking and primary-email logins in your phone's normal browser.
* **No root desktop session.** Applications run as the unprivileged guest user (password-locked).
  Root is used only by the installer inside the PRoot guest. PRoot "root" is not real root.
* **Supply chain.** Packages come from Termux and Debian repositories (signature-checked by apt).
  code-server is downloaded over HTTPS from its GitHub releases; this installer prints the SHA-256
  of the file but does **not** verify it against a publisher checksum. Reading the scripts first
  (clone, then run) is recommended over `curl | bash`.
* **Termux theme.** Only `~/.termux/colors.properties` is changed, after explicit consent, with a
  timestamped backup that is never overwritten.
* **AI helper (optional).** Prompts - and, for `ai fix`, the last lines of a command's output - are
  sent to the provider you configure. That data leaves your phone and may cost money.

## Contributor checklist

- Run `shellcheck -x -S warning` on every script you touch.
- Quote all expansions; use `set -Eeuo pipefail`; avoid `eval`.
- Never put secrets in argv, environment dumps or logs.
- Validate any user-controlled value before using it in a path, regex or command.
