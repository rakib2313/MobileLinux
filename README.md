# MobileLinux

A modular **Linux desktop environment for Android phones**, built from shell scripts that set up a
**Debian** userspace with **XFCE4** and **TigerVNC** inside **Termux** using **PRoot-Distro**. You view the
desktop with a VNC client app on the same phone.

> **This is a Termux/PRoot Linux userspace — not a standalone Android replacement OS and not a custom ROM.**
> It runs *on top of* Android. It does not need root. Repository: <https://github.com/rakib2313/MobileLinux>

Aimed at beginner web developers who want a Linux desktop and common dev tools on an ARM64 phone.

**Status:** the scripts were reviewed and syntax-checked on a PC. They have **not** been tested on a real
Android/Termux device by the author of this generator. Expect to troubleshoot, and please report what you find.

## Features

* One installer (`scripts/install.sh`) that is safe to re-run and does not delete guest data.
* Debian guest via PRoot-Distro, minimal XFCE4 desktop, TigerVNC bound to **localhost only**.
* Three hardware profiles (`low`, `mid`, `high`) with automatic recommendation and manual override.
* Dev tools from Debian packages: Git, curl, wget, Python 3, Node.js, npm, plus small utilities.
* Optional: Chromium or Firefox ESR (if packages exist and work), code-server via npm, AI helper script.
* No systemd, Docker or root required.

## Known limitations (please read)

* PRoot translates system calls in userspace: it is slower than native Linux, has no systemd, no Docker,
  limited kernel features, and **no GPU acceleration** (software rendering).
* Android may kill Termux in the background (phantom-process limits, battery optimisation). Long sessions can be interrupted.
* VNC is not encrypted (see Security). Remote-desktop latency and text sharpness depend on the device and client.
* Browsers often fail under PRoot because their sandboxes need kernel features Android may block.
  The **Android browser** is the practical way to open local web apps. Debian package versions can be older than upstream.
* Performance, heat/thermal throttling and battery drain depend on your device, Android version, free storage,
  workload and background restrictions. **No profile can guarantee smooth performance.**

## Supported architecture and prerequisites

* **ARM64 / aarch64 only.** The installer refuses other architectures with an explanation.
* A current Termux. Install it from the sources the Termux project recommends (F-Droid or the project's GitHub
  releases). Old builds from other stores are outdated and their package repositories may no longer work,
  which causes `pkg` errors. Do not mix builds from different sources (their signing keys differ).
  Check the Termux wiki for current guidance.
* Estimates only (not measured): **4+ GB** free storage for the base desktop (more with apps),
  **~4 GB RAM** as a practical floor (the low profile targets this), a stable network for the first install.
* A VNC client app on Android (any client that supports plain VNC to `localhost`).

## Where each command runs

| Label | Where | How to get there |
|-------|-------|------------------|
| **[Termux]** | Android / Termux host | open the Termux app |
| **[Guest]** | Debian inside PRoot | `bash scripts/shell.sh` (from Termux) |
| **[VNC client]** | the VNC app on Android | connect to `localhost:5901` |

Almost everything is run from **[Termux]**; the scripts call into the guest for you.

## Install

**[Termux]** install prerequisites and clone:

```bash
pkg update && pkg upgrade
pkg install -y git
git clone https://github.com/rakib2313/MobileLinux.git
cd MobileLinux
```

Inspect the installer before running it (there is intentionally no `curl | bash` one-liner):

```bash
less scripts/install.sh
```

**[Termux]** run it (the optional flags are listed with `--help`):

```bash
bash scripts/install.sh
```

Other examples: `bash scripts/install.sh --profile low --skip-apps`, `bash scripts/install.sh --browser none`,
`bash scripts/install.sh --code-server`, `bash scripts/install.sh --yes`.

### Choose a hardware profile

| Profile | Default resolution | Intent |
|---------|--------------------|--------|
| low  | 1280x720  | small devices (~4 GB RAM class); minimal extras; no browser by default |
| mid  | 1600x900  | balanced; a few extra desktop apps; Chromium attempted |
| high | 1920x1080 | more conveniences; compositing on |

`auto` picks from total RAM read from `/proc/meminfo`. That is best effort: phones report less than their
marketing RAM and detection can be wrong, so always override if the result seems off.

**[Termux]**

```bash
bash scripts/select-profile.sh            # show detection and options
bash scripts/select-profile.sh low        # or mid / high / auto
bash scripts/setup-vnc.sh resolution 1280x720   # custom resolution; 'reset' removes it
bash scripts/setup-vnc.sh restart         # apply
```

Profile files live in `configs/profiles/`. To apply package changes (extras) after switching, re-run `bash scripts/install.sh --skip-upgrade`.

## Use the desktop

**[Termux]**

```bash
bash scripts/setup-vnc.sh passwd     # once: choose a VNC password (only the first 8 characters count)
bash scripts/setup-vnc.sh start
bash scripts/setup-vnc.sh status
bash scripts/setup-vnc.sh stop
```

**[VNC client]** create a connection to host `localhost` (or `127.0.0.1`), port `5901` (display `:1`), and enter the
password you chose. Optionally keep the device awake and exempt Termux from battery optimisation to reduce kills.

## Web development

**[Guest]** (`bash scripts/shell.sh`):

```bash
mkdir -p ~/site && cd ~/site
echo '<h1>Hello</h1>' > index.html
python3 -m http.server 8000 --bind 127.0.0.1
```

Then open `http://127.0.0.1:8000` in the **Android browser** (PRoot shares the phone's network). Node tools work the
same way (`node --version`, `npm init`). Bind dev servers to `127.0.0.1`.

**code-server (optional)** — installed only with `--code-server`, via npm; compatibility with Debian's Node.js is not
guaranteed and untested. **[Guest]**: `~/.local/bin/code-server`, then open `http://127.0.0.1:8080` in the Android browser.
Its password is in `~/.config/code-server/config.yaml`. A desktop VS Code build is not assumed to work in PRoot.

## Browsers

Use the Android browser by default. Optional in-guest browsers: `--browser chromium` (launcher: `mobilelinux-chromium`,
flags in `configs/chromium/flags.conf`) or `--browser firefox`. If a browser crashes at start, its sandbox probably
cannot work under PRoot. MobileLinux does **not** disable sandboxes for you. For Chromium only, you may opt in with
`MOBILELINUX_CHROMIUM_NO_SANDBOX=1 mobilelinux-chromium` — understand that this weakens protection against malicious
pages, and prefer the Android browser instead.

## Optional AI helper

`scripts/ai-assistant.sh` is a small curl+jq wrapper for an OpenAI-chat-style endpoint you configure
(`AI_API_ENDPOINT`, `AI_MODEL`, `AI_API_KEY`; see the header of the script and `.env.example`). Nothing else needs it.
Prompts and piped files are sent to that provider, may incur costs and need internet. Do not send secrets.

## Security and privacy

Summary (details in [SECURITY.md](SECURITY.md)): PRoot is not a strong sandbox; VNC runs on loopback only; VNC
password auth is **not encryption** — use an SSH tunnel or another encrypted tunnel for any remote access; never commit
secrets; read scripts before running them.

## Troubleshooting

* **`pkg` errors / 404 / mirror problems:** run `termux-change-repo`, then `pkg update && pkg upgrade`. Make sure
  your Termux is a current one (see prerequisites).
* **Installer stops or apt fails:** it is safe to re-run `bash scripts/install.sh`. Check `df -h` for space. Under PRoot
  `apt` can print sandbox warnings; if downloads fail with `seteuid`/`setgroups` errors, search the proot-distro issue tracker for the current workaround.
* **VNC client cannot connect:** `bash scripts/setup-vnc.sh status`; make sure it is running and the client uses `localhost:5901`.
  Read the log in the guest: `bash scripts/shell.sh` then `ls ~/.vnc/*.log`. Stale locks are cleaned automatically on `start`.
  Grey screen: check `~/.vnc/*.log` for errors from `xstartup`.
* **Session disappears after a while:** Android killed Termux. Disable battery optimisation for Termux, keep it in the
  foreground, and consider `termux-wake-lock` (Termux feature). Some vendors are aggressive regardless.
* **Browser crashes:** see Browsers. Use the Android browser.
* **Slow or hot device:** use `low`, lower the resolution (`setup-vnc.sh resolution 1024x600`), close apps, avoid heavy builds.
* **Storage full:** `du -sh $PREFIX/var/lib/proot-distro/installed-rootfs/*`; back up and remove what you do not need.

## Uninstall and cleanup

**[Termux]** `bash scripts/uninstall.sh` removes the Debian guest. **This permanently deletes everything inside it,
including `/home/mluser` (your projects).** Back up first (copy files out, or `proot-distro backup debian --output ...` if
your proot-distro supports it). The script asks you to type the guest name before deleting. The repository directory and
`pkg` packages are left alone; remove them yourself if you wish.

## Project layout

```
MobileLinux/
├── .github/workflows/static-checks.yml   shell syntax + ShellCheck (no Android testing)
├── assets/
├── configs/{profiles,vnc,chromium}/
├── scripts/
│   ├── install.sh  select-profile.sh  setup-vnc.sh  shell.sh  uninstall.sh  ai-assistant.sh
│   ├── lib/common.sh
│   └── guest/{provision,user-setup,install-apps,install-code-server,vncctl}.sh, mobilelinux-chromium
├── .env.example  .gitignore  LICENSE  README.md  SECURITY.md
```

## License

MIT — see [LICENSE](LICENSE). Copyright rakib2313. Source: <https://github.com/rakib2313/MobileLinux>
