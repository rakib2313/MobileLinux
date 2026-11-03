#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# common.sh - shared helpers for MobileLinux (sourced, never executed)
#   * colours + glyphs with NO_COLOR / ASCII fallbacks
#   * logging to the terminal and to a private log file (with fallback)
#   * secret redaction, arch/RAM detection, traps, prompts, retry, apt helpers
# =============================================================================

if [ -n "${MLD_COMMON_LOADED:-}" ]; then
  return 0
fi
MLD_COMMON_LOADED=1

MLD_VERSION="2.0.0"
MLD_LAST_ERROR=""

# ---- colours and glyphs -----------------------------------------------------
# Re-run mld_ui_init after changing MLD_NO_COLOR / MLD_ASCII.
mld_ui_init() {
  local color=1 uni=1 loc
  if [ -n "${NO_COLOR:-}" ] || [ "${MLD_NO_COLOR:-0}" = "1" ] || [ ! -t 2 ] || [ "${TERM:-dumb}" = "dumb" ]; then
    color=0
  fi
  if [ "$color" = 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
  else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""
    C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
  fi
  loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  case "$loc" in
    ''|*[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
    *) uni=0 ;;
  esac
  if [ "${MLD_ASCII:-0}" = "1" ] || [ ! -t 2 ]; then
    uni=0
  fi
  if [ "$uni" = 1 ]; then
    G_OK="✔"; G_FAIL="✖"; G_WARN="!"; G_INFO="•"; G_SKIP="–"; G_RULE="─"
    SPIN_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  else
    G_OK="+"; G_FAIL="x"; G_WARN="!"; G_INFO="-"; G_SKIP="~"; G_RULE="-"
    SPIN_FRAMES=('|' '/' '-' '\')
  fi
}
mld_ui_init

# ---- log file (private; falls back to $TMPDIR, then to "live output only") ---
MLD_LOG_FILE="${MLD_LOG_FILE:-${HOME}/.cache/mld/mld.log}"

_mld_try_log() { # path
  ( umask 077; mkdir -p "$(dirname "$1")" && : >>"$1" ) 2>/dev/null || return 1
  chmod 600 "$1" 2>/dev/null || true
}

mld_file_size() { # path
  stat -c %s "$1" 2>/dev/null || echo 0
}

mld_log_init() {
  local f="$MLD_LOG_FILE" alt
  if _mld_try_log "$f"; then
    if [ "$(mld_file_size "$f")" -gt 5242880 ]; then
      mv -f -- "$f" "$f.1" 2>/dev/null && _mld_try_log "$f" || true
    fi
    return 0
  fi
  alt="${TMPDIR:-/tmp}/mld-$(id -u).log"
  if _mld_try_log "$alt"; then
    MLD_LOG_FILE="$alt"
    printf '[mld] WARNING: cannot write %s - logging to %s instead.\n' "$f" "$alt" >&2
    return 0
  fi
  MLD_LOG_FILE=/dev/null
  printf '[mld] WARNING: logging is disabled (cannot write %s or %s). Command output will be shown live.\n' "$f" "$alt" >&2
}
mld_log_init

mld_log_raw() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$MLD_LOG_FILE" 2>/dev/null || true
}

# Masks common secret shapes. Used before showing log lines or diagnostics.
mld_redact() {
  sed -E \
    -e 's#([A-Za-z0-9_]*(PASSWORD|PASSWD|SECRET|TOKEN|APIKEY|API_KEY|_KEY)[A-Za-z0-9_]*[=:][[:space:]]*)[^[:space:]]+#\1[REDACTED]#Ig' \
    -e 's#(Bearer[[:space:]]+)[A-Za-z0-9._~+/=-]+#\1[REDACTED]#Ig' \
    -e 's#(sk-|ghp_)[A-Za-z0-9_-]{16,}#[REDACTED]#g'
}

# ---- logging ----------------------------------------------------------------
_mld_emit() { # level colour glyph message...
  local level="$1" colour="$2" glyph="$3"
  shift 3
  printf '  %s%s%s %s\n' "$colour" "$glyph" "$C_RESET" "$*" >&2
  mld_log_raw "[$level] $*"
}
log_info() { _mld_emit INFO "$C_BLUE" "$G_INFO" "$*"; }
log_ok()   { _mld_emit OK "$C_GREEN" "$G_OK" "$*"; }
log_warn() { _mld_emit WARN "$C_YELLOW" "$G_WARN" "$*"; }
log_err()  { _mld_emit FAIL "$C_RED" "$G_FAIL" "$*"; }
log_step() { printf '\n%s==> %s%s\n' "${C_BOLD}${C_CYAN}" "$*" "$C_RESET" >&2; mld_log_raw "[STEP] $*"; }

die() {
  MLD_LAST_ERROR="$*"
  if [ "${UI_ERROR_SCREEN:-0}" = "1" ]; then
    mld_log_raw "[FAIL] $*"
  else
    log_err "$*"
  fi
  exit 1
}

# ---- traps / cleanup --------------------------------------------------------
MLD_TMP_FILES=()

mld_cleanup() {
  local f
  for f in "${MLD_TMP_FILES[@]:-}"; do
    if [ -n "$f" ]; then
      rm -rf -- "$f"
    fi
  done
}

mld_on_err() {
  local rc=$? line="${BASH_LINENO[0]:-?}" src="${BASH_SOURCE[1]:-$0}" cmd
  cmd="$(printf '%s' "${BASH_COMMAND:-?}" | mld_redact)"
  MLD_LAST_ERROR="Unexpected error in ${src##*/}:${line}: ${cmd}"
  mld_log_raw "[FAIL] ${MLD_LAST_ERROR} (exit ${rc})"
  if [ "${UI_ERROR_SCREEN:-0}" != "1" ]; then
    log_err "Unexpected error (exit ${rc}) at ${src##*/}:${line} -> ${cmd}"
    log_err "Full log: ${MLD_LOG_FILE}"
  fi
}

mld_on_exit() {
  local rc=$?
  if declare -F ui_on_exit >/dev/null 2>&1; then
    ui_on_exit "$rc"
  fi
  mld_cleanup
}

mld_enable_traps() {
  trap mld_on_err ERR
  trap mld_on_exit EXIT
  trap 'log_warn "Interrupted by user. Nothing was deleted; re-run to resume."; exit 130' INT TERM
}

# ---- environment detection --------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

mld_is_termux() {
  [ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux/files/usr ]
}

mld_arch() {
  case "$(uname -m)" in
    aarch64|arm64)        echo aarch64 ;;
    armv7l|armv8l|arm)    echo arm ;;
    x86_64|amd64)         echo x86_64 ;;
    *)                    echo unsupported ;;
  esac
}

mld_deb_arch() {
  case "$(mld_arch)" in
    aarch64) echo arm64 ;;
    arm)     echo armhf ;;
    x86_64)  echo amd64 ;;
    *)       echo unknown ;;
  esac
}

mld_require_supported_arch() {
  if [ "$(mld_arch)" = "unsupported" ]; then
    die "Unsupported CPU architecture: $(uname -m) (need ARM64, ARM32 or x86_64)"
  fi
}

# Prints total RAM in MB from /proc/meminfo, or 0 when it cannot be read.
# Limitation: this is the device total, not what Android lets one app use.
mld_ram_mb() {
  local kb
  kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
  case "$kb" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo $((kb / 1024)) ;;
  esac
}

# low: <= ~4 GB (or unknown) | mid: ~6 GB | high: 8 GB and up
mld_pick_profile() {
  local ram
  ram="$(mld_ram_mb)"
  if [ "$ram" -le 4608 ]; then
    echo low
  elif [ "$ram" -le 6656 ]; then
    echo mid
  else
    echo high
  fi
}

# Free MB on the filesystem holding $1 (empty output if df cannot tell).
mld_free_mb() { # path
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print int($4/1024)}'
}

# True when the proot-distro container exists. Tries known storage layouts and
# finally asks proot-distro itself, so no single layout is assumed.
mld_distro_installed() { # name
  local base="${PREFIX:-/data/data/com.termux/files/usr}/var/lib/proot-distro"
  if [ -d "$base/containers/$1/rootfs" ] || [ -d "$base/installed-rootfs/$1" ]; then
    return 0
  fi
  have_cmd proot-distro && proot-distro login "$1" -- /bin/true >/dev/null 2>&1
}

# ---- profile loading --------------------------------------------------------
mld_load_profile() { # file
  local f="$1"
  [ -r "$f" ] || die "Profile/config file not readable: $f"
  # shellcheck source=/dev/null
  . "$f"
}

# ---- safe .env loader (parsed, never executed; values are never logged) ------
mld_load_env_file() { # file
  local file="$1" line key val mode
  [ -f "$file" ] || return 0
  mode="$(stat -c '%a' "$file" 2>/dev/null || echo 600)"
  if [ "$mode" != "600" ]; then
    chmod 600 "$file" 2>/dev/null || true
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key="${line%%=*}"
    val="${line#*=}"
    key="${key//[[:space:]]/}"
    [[ "$key" =~ ^MLD_[A-Z0-9_]+$ ]] || continue
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    [ -n "$val" ] || continue
    if [ -z "${!key:-}" ]; then
      printf -v "$key" '%s' "$val"
      export "$key"
    fi
  done <"$file"
}

# ---- prompts (use the real terminal even when stdin is a pipe) --------------
mld_tty() {
  if [ -t 0 ]; then
    echo /dev/stdin
    return 0
  fi
  if [ -r /dev/tty ] && ( : </dev/tty ) 2>/dev/null; then
    echo /dev/tty
    return 0
  fi
  return 1
}

_mld_ask() { # question default honor_yes(1|0)
  local q="$1" def="${2:-n}" honor="${3:-1}" ans in hint
  if [ "$honor" = 1 ] && [ "${MLD_ASSUME_YES:-0}" = "1" ]; then
    return 0
  fi
  if ! in="$(mld_tty)"; then
    if [ "$honor" = 1 ] && [ "$def" = "y" ]; then
      return 0
    fi
    return 1
  fi
  if [ "$def" = "y" ]; then hint="Y/n"; else hint="y/N"; fi
  printf '  %s?%s %s [%s] ' "$C_CYAN" "$C_RESET" "$q" "$hint" >&2
  IFS= read -r ans <"$in" || ans=""
  ans="${ans:-$def}"
  case "$ans" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# mld_confirm honours --yes. mld_confirm_strict never does (used for consent to
# change the user's appearance or security settings; no terminal means "no").
mld_confirm() { _mld_ask "$1" "${2:-n}" 1; }
mld_confirm_strict() { _mld_ask "$1" "${2:-n}" 0; }

mld_prompt() { # label default varname
  local in v
  if ! in="$(mld_tty)"; then
    printf -v "$3" '%s' "$2"
    return 0
  fi
  printf '  %s%s: ' "$1" "${2:+ [$2]}" >&2
  IFS= read -r v <"$in" || v=""
  printf -v "$3" '%s' "${v:-$2}"
}

mld_prompt_secret() { # label varname
  local in v
  in="$(mld_tty)" || return 1
  printf '  %s: ' "$1" >&2
  IFS= read -r -s v <"$in" || v=""
  printf '\n' >&2
  printf -v "$2" '%s' "$v"
}

# ---- retry + process helpers -------------------------------------------------
retry() { # attempts delay cmd...
  local attempts="$1" delay="$2" i=1
  shift 2
  until "$@"; do
    if [ "$i" -ge "$attempts" ]; then
      return 1
    fi
    log_warn "Command failed (attempt ${i}/${attempts}); retrying in ${delay}s: $1"
    sleep "$delay"
    i=$((i + 1))
  done
}

mld_kill_tree() { # pid [signal]
  local pid="$1" sig="${2:-TERM}" child
  if have_cmd pgrep; then
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do
      mld_kill_tree "$child" "$sig"
    done
  fi
  kill "-${sig}" "$pid" 2>/dev/null || true
}

# Machine-readable component status shared with the host through $MLD_STATUS_FILE
#   STATUS|component|ok|warn|skip|fail|note|how-to-fix-later
# ok = fine, warn = optional part failed, skip = optional part skipped,
# fail = REQUIRED part missing/broken.
mld_status() { # component state note [fix]
  local f="${MLD_STATUS_FILE:-}"
  [ -n "$f" ] || return 0
  printf 'STATUS|%s|%s|%s|%s\n' "$1" "$2" \
    "$(printf '%s' "${3:-}" | tr '|\n' '/ ')" "$(printf '%s' "${4:-}" | tr '|\n' '/ ')" >>"$f" 2>/dev/null || true
}

# ---- Debian / apt helpers (used inside the guest) -------------------------------
mld_noninteractive_env() {
  export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true DEBIAN_PRIORITY=critical
  export APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a UCF_FORCE_CONFFOLD=1
}

# Clear stale locks and finish half-configured packages left by an interrupted run.
mld_apt_recover() {
  # Never remove dpkg/apt lock files: another package manager may hold them.
  timeout -k 10 600 dpkg --force-confold --configure -a </dev/null >/dev/null 2>&1 || true
}

# apt-get with a hard time limit; repairs the package state if it fails or times out.
mld_apt() { # apt-get arguments...
  local rc=0
  if [ "${MLD_APT_TIMEOUT:-0}" = 0 ]; then
    apt-get "$@" </dev/null || rc=$?
  else
    timeout -k 30 "$MLD_APT_TIMEOUT" apt-get "$@" </dev/null || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    log_warn "apt-get $1 failed or timed out (exit ${rc}); repairing package state"
    mld_apt_recover
  fi
  return "$rc"
}
