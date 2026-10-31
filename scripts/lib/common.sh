#!/usr/bin/env bash
# MobileLinux shared helper library (Bash, not POSIX sh).
# Source it from other scripts:  source "<scripts dir>/lib/common.sh"
# Used both on the Termux host and inside the Debian guest.
# shellcheck shell=bash

if [[ -n "${_ML_COMMON_LOADED:-}" ]]; then
  return 0
fi
_ML_COMMON_LOADED=1

ML_REPO_URL="https://github.com/rakib2313/MobileLinux.git"
ML_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ML_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mobilelinux"
ML_CONFIG_FILE="${ML_CONFIG_FILE:-$ML_CONFIG_DIR/config.env}"
ML_PROFILES=(low mid high)
_ML_TMP_PATHS=()

# ---------------------------------------------------------------- logging
if [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
  _C_RESET=$'\033[0m'; _C_RED=$'\033[31m'; _C_GREEN=$'\033[32m'
  _C_YELLOW=$'\033[33m'; _C_BLUE=$'\033[34m'; _C_BOLD=$'\033[1m'
else
  _C_RESET=""; _C_RED=""; _C_GREEN=""; _C_YELLOW=""; _C_BLUE=""; _C_BOLD=""
fi

# All log output goes to stderr so stdout stays usable for data.
ml_info() { printf '%s[INFO]%s  %s\n' "$_C_BLUE" "$_C_RESET" "$*" >&2; }
ml_ok()   { printf '%s[ OK ]%s  %s\n' "$_C_GREEN" "$_C_RESET" "$*" >&2; }
ml_warn() { printf '%s[WARN]%s  %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
ml_err()  { printf '%s[FAIL]%s  %s\n' "$_C_RED" "$_C_RESET" "$*" >&2; }
ml_step() { printf '\n%s==> %s%s\n' "$_C_BOLD" "$*" "$_C_RESET" >&2; }

# ml_die "message" [exit_code]
ml_die() {
  local code="${2:-1}"
  ml_err "$1"
  exit "$code"
}

_ml_on_err() {
  ml_err "Unexpected failure (exit status $1) near line $2 of ${3##*/}."
}

# Call once near the top of an executable script (not of a sourced library).
ml_install_traps() {
  set -Eeuo pipefail
  trap ml_cleanup EXIT
  trap 'ml_err "Interrupted."; exit 130' INT TERM
  trap '_ml_on_err "$?" "$LINENO" "${BASH_SOURCE[0]}"' ERR
}

# ---------------------------------------------------------------- temp files
# ml_mktemp VAR [dir]  -> creates a temp file (or dir) and stores its path in VAR.
# (Not command substitution, so the cleanup list survives in this shell.)
ml_mktemp() {
  local __var="$1" __kind="${2:-file}" __p
  umask 077
  if [[ "$__kind" == dir ]]; then
    __p="$(mktemp -d "${TMPDIR:-/tmp}/mobilelinux.XXXXXX")" || return 1
  else
    __p="$(mktemp "${TMPDIR:-/tmp}/mobilelinux.XXXXXX")" || return 1
  fi
  _ML_TMP_PATHS+=("$__p")
  printf -v "$__var" '%s' "$__p"
}

ml_cleanup() {
  local p
  for p in "${_ML_TMP_PATHS[@]:-}"; do
    # Only ever remove paths this library created.
    if [[ -n "$p" && "$p" == "${TMPDIR:-/tmp}"/mobilelinux.* ]]; then
      rm -rf -- "$p"
    fi
  done
  return 0
}

# ---------------------------------------------------------------- checks
ml_have() { command -v "$1" >/dev/null 2>&1; }

# ml_require cmd... : die with a list of missing commands.
ml_require() {
  local c missing=()
  for c in "$@"; do
    ml_have "$c" || missing+=("$c")
  done
  if ((${#missing[@]} > 0)); then
    ml_die "Missing required command(s): ${missing[*]}"
  fi
}

ml_is_termux() {
  [[ -n "${TERMUX_VERSION:-}" || "${PREFIX:-}" == *com.termux* ]]
}

ml_detect_arch() {
  case "$(uname -m)" in
    aarch64|arm64) echo aarch64 ;;
    x86_64|amd64)  echo x86_64 ;;
    armv7l|armv8l|arm) echo arm32 ;;
    *) uname -m ;;
  esac
}

# Fails (exit via ml_die) unless the architecture is aarch64.
ml_check_arch() {
  local arch
  arch="$(ml_detect_arch)"
  if [[ "$arch" == aarch64 ]]; then
    return 0
  fi
  if [[ "${ML_ALLOW_UNSUPPORTED_ARCH:-0}" == 1 ]]; then
    ml_warn "Architecture '$arch' is NOT supported by this project. Continuing because ML_ALLOW_UNSUPPORTED_ARCH=1; expect problems."
    return 0
  fi
  ml_die "Unsupported architecture '$arch'. MobileLinux targets ARM64 (aarch64) only. (Override at your own risk: ML_ALLOW_UNSUPPORTED_ARCH=1.)"
}

# Prints total RAM in MiB, or 0 if it cannot be determined (best effort).
ml_detect_mem_mb() {
  local kb=""
  if [[ -r /proc/meminfo ]]; then
    kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
  fi
  if [[ -z "$kb" ]] && ml_have free; then
    kb="$(free -k 2>/dev/null | awk '/^Mem:/ {print $2; exit}' || true)"
  fi
  if [[ "$kb" =~ ^[0-9]+$ ]]; then
    echo $((kb / 1024))
  else
    echo 0
  fi
}

# Phones report less than their marketing RAM (a "4 GB" phone often shows ~3.5 GB).
ml_recommend_profile() {
  local mb
  mb="$(ml_detect_mem_mb)"
  if ((mb == 0 || mb < 5000)); then
    echo low
  elif ((mb < 10000)); then
    echo mid
  else
    echo high
  fi
}

ml_confirm() { # ml_confirm "question"  (default: no; non-interactive: no unless ML_ASSUME_YES=1)
  local ans
  if [[ "${ML_ASSUME_YES:-0}" == 1 ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    return 1
  fi
  read -r -p "$1 [y/N] " ans || return 1
  [[ "$ans" == [yY] || "$ans" == [yY][eE][sS] ]]
}

# ---------------------------------------------------------------- config
# Safe KEY=VALUE loader: never executes file content.
# ml_load_env_file FILE PREFIX_REGEX [force]
# Existing environment variables win unless force=1.
ml_load_env_file() {
  local file="$1" prefix_re="$2" force="${3:-0}" line key val
  local dq='"' sq="'"
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^[[:space:]]*(#|$) ]]; then
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[2]}"
      val="${BASH_REMATCH[3]}"
    else
      continue
    fi
    if ! [[ "$key" =~ $prefix_re ]]; then
      continue
    fi
    if [[ "$val" =~ ^${dq}(.*)${dq}[[:space:]]*$ ]]; then
      val="${BASH_REMATCH[1]}"
    elif [[ "$val" =~ ^${sq}(.*)${sq}[[:space:]]*$ ]]; then
      val="${BASH_REMATCH[1]}"
    else
      val="${val%%[[:space:]]#*}"
      val="${val%"${val##*[![:space:]]}"}"
    fi
    if [[ "$force" == 1 || -z "${!key+x}" ]]; then
      printf -v "$key" '%s' "$val"
      export "${key?}"
    fi
  done <"$file"
  return 0
}

# Atomically set/unset a key in the user config file (mode 600).
ml_config_set() {
  local key="$1" val="$2" tmp
  [[ "$key" =~ ^ML_[A-Z0-9_]+$ ]] || ml_die "Invalid config key: $key"
  [[ "$val" =~ ^[A-Za-z0-9_./:@+x-]*$ ]] || ml_die "Invalid characters in value for $key"
  mkdir -p "$ML_CONFIG_DIR"
  chmod 700 "$ML_CONFIG_DIR" 2>/dev/null || true
  tmp="$(mktemp "$ML_CONFIG_DIR/.config.XXXXXX")"
  if [[ -f "$ML_CONFIG_FILE" ]]; then
    grep -v "^${key}=" "$ML_CONFIG_FILE" >"$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$val" >>"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$ML_CONFIG_FILE"
}

ml_config_unset() {
  local key="$1" tmp
  [[ "$key" =~ ^ML_[A-Z0-9_]+$ ]] || ml_die "Invalid config key: $key"
  [[ -f "$ML_CONFIG_FILE" ]] || return 0
  tmp="$(mktemp "$ML_CONFIG_DIR/.config.XXXXXX")"
  grep -v "^${key}=" "$ML_CONFIG_FILE" >"$tmp" || true
  chmod 600 "$tmp"
  mv -f "$tmp" "$ML_CONFIG_FILE"
}

# Precedence: real environment > ~/.config/mobilelinux/config.env > <project>/.env > defaults
ml_load_config() {
  ml_load_env_file "$ML_CONFIG_FILE" '^ML_'
  ml_load_env_file "$ML_ROOT/.env" '^ML_'
  : "${ML_DISTRO:=debian}"
  : "${ML_USER:=mluser}"
  : "${ML_PROFILE:=auto}"
  : "${ML_VNC_DISPLAY:=1}"
  if ! [[ "$ML_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$ML_USER" != root ]]; then
    ml_die "ML_USER='$ML_USER' is invalid (lowercase letters/digits/_/-; not 'root')."
  fi
  if ! [[ "$ML_DISTRO" =~ ^[a-z0-9_.-]+$ ]]; then
    ml_die "ML_DISTRO='$ML_DISTRO' is invalid."
  fi
  if ! [[ "$ML_VNC_DISPLAY" =~ ^[0-9]{1,2}$ ]] || ((ML_VNC_DISPLAY < 1)); then
    ml_die "ML_VNC_DISPLAY='$ML_VNC_DISPLAY' must be a number from 1 to 99."
  fi
}

ml_profile_valid() { [[ " ${ML_PROFILES[*]} " == *" $1 "* ]]; }

ml_resolve_profile() {
  local p="${ML_PROFILE:-auto}"
  if [[ "$p" == auto ]]; then
    p="$(ml_recommend_profile)"
  fi
  ml_profile_valid "$p" || ml_die "Unknown profile '$p' (expected: auto ${ML_PROFILES[*]})."
  ML_PROFILE_RESOLVED="$p"
}

# Loads configs/profiles/<name>.conf and derives ML_GEOMETRY etc.
ml_load_profile() {
  local name="$1" file
  ml_profile_valid "$name" || ml_die "Unknown profile '$name' (expected: ${ML_PROFILES[*]})."
  file="$ML_ROOT/configs/profiles/$name.conf"
  [[ -r "$file" ]] || ml_die "Profile file not found: $file"
  ml_load_env_file "$file" '^PROFILE_' 1
  ML_GEOMETRY="${ML_GEOMETRY_OVERRIDE:-${PROFILE_GEOMETRY:-1280x720}}"
  if ! [[ "$ML_GEOMETRY" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]]; then
    ml_die "Invalid resolution '$ML_GEOMETRY' (expected WIDTHxHEIGHT, e.g. 1280x720)."
  fi
  ML_DEPTH="${PROFILE_DEPTH:-24}"
  ML_COMPOSITING="${PROFILE_COMPOSITING:-false}"
  ML_BROWSER_DEFAULT="${PROFILE_BROWSER:-none}"
  ML_EXTRA_PACKAGES="${PROFILE_EXTRA_PACKAGES:-}"
}

# ---------------------------------------------------------------- apt helpers (guest)
ml_apt_available() { # package has an installable candidate
  local cand
  cand="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
  [[ -n "$cand" && "$cand" != "(none)" ]]
}

# Installs packages that exist; warns about the rest. Never fails because of absent packages.
ml_apt_install_optional() {
  local pkg ok=()
  for pkg in "$@"; do
    if ml_apt_available "$pkg"; then
      ok+=("$pkg")
    else
      ml_warn "Package not available for this Debian release/architecture, skipping: $pkg"
    fi
  done
  if ((${#ok[@]} > 0)); then
    apt-get install -y --no-install-recommends "${ok[@]}" || ml_warn "Some optional packages failed to install: ${ok[*]}"
  fi
  return 0
}

# ---------------------------------------------------------------- host: guest management
ml_guest_installed() {
  local dir="${PREFIX:-/data/data/com.termux/files/usr}/var/lib/proot-distro/installed-rootfs/$ML_DISTRO"
  [[ -d "$dir" ]] && return 0
  ml_have proot-distro && proot-distro login "$ML_DISTRO" -- true >/dev/null 2>&1
}

# ml_guest_exec USER command [args...]  (runs inside the Debian guest; project mounted at /opt/MobileLinux)
ml_guest_exec() {
  local user="$1"
  shift
  ml_have proot-distro || ml_die "proot-distro is not installed. Run: bash scripts/install.sh"
  ml_resolve_profile
  local envs=("ML_PROFILE=$ML_PROFILE_RESOLVED" "ML_USER=$ML_USER" "ML_VNC_DISPLAY=$ML_VNC_DISPLAY" \
    "ML_ASSUME_YES=${ML_ASSUME_YES:-0}" "TERM=${TERM:-xterm}")
  if [[ -n "${ML_GEOMETRY_OVERRIDE:-}" ]]; then
    envs+=("ML_GEOMETRY_OVERRIDE=$ML_GEOMETRY_OVERRIDE")
  fi
  proot-distro login "$ML_DISTRO" --user "$user" --bind "$ML_ROOT:/opt/MobileLinux" -- env "${envs[@]}" "$@"
}
