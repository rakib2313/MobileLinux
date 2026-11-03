#!/usr/bin/env bash
# =============================================================================
# setup-theme.sh - optional MobileLinux colour theme for the Termux terminal
#   mld theme apply [--yes]     back up ~/.termux/colors.properties, install theme
#   mld theme restore [--yes]   put the previous file back (or remove ours)
#   mld theme status            exit 0 if the MobileLinux theme is active
#   mld theme backups           list backups
# Touches ONLY ~/.termux/colors.properties. No font is downloaded or changed.
# It does not change the Android system theme, the XFCE desktop or your VNC app.
# Backups: ~/.termux/mobilelinux-backups/colors.properties.<timestamp>
#          (never overwritten, never deleted by this project)
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
mld_enable_traps

# MLD_TERMUX_DIR is a testing override; normally ~/.termux is used.
TERMUX_DIR="${MLD_TERMUX_DIR:-$HOME/.termux}"
TARGET="$TERMUX_DIR/colors.properties"
BACKUP_DIR="$TERMUX_DIR/mobilelinux-backups"
STATE="$BACKUP_DIR/state"
THEME_SRC="$SCRIPT_DIR/../configs/termux/colors.properties"
ASSUME_YES=0

theme_is_applied() {
  [ -f "$TARGET" ] && [ -f "$THEME_SRC" ] && cmp -s -- "$TARGET" "$THEME_SRC"
}

state_get() { # key (letters only)
  [ -f "$STATE" ] || return 0
  sed -n "s/^$1=//p" "$STATE" | tail -n 1
}

state_write() { # had_original backup_path status
  local tmp="$STATE.tmp.$$"
  ( umask 077; printf 'HAD_ORIGINAL=%s\nBACKUP=%s\nSTATUS=%s\nUPDATED=%s\n' \
      "$1" "$2" "$3" "$(date '+%Y-%m-%dT%H:%M:%S')" >"$tmp" )
  mv -f -- "$tmp" "$STATE"
}

# Creates a timestamped copy that never replaces an existing backup.
make_backup() { # source label  -> prints the new path
  local src="$1" label="${2:-}" stamp dest n=0
  stamp="$(date '+%Y%m%d-%H%M%S')"
  ( umask 077; mkdir -p "$BACKUP_DIR" )
  chmod 700 "$BACKUP_DIR" 2>/dev/null || true
  dest="$BACKUP_DIR/colors.properties.${label}${stamp}"
  while [ -e "$dest" ]; do
    n=$((n + 1))
    dest="$BACKUP_DIR/colors.properties.${label}${stamp}-${n}"
  done
  ( set -o noclobber; umask 077; cat -- "$src" >"$dest" ) || die "Could not create backup: $dest"
  cmp -s -- "$src" "$dest" || die "Backup verification failed: $dest"
  printf '%s' "$dest"
}

install_file() { # source destination (atomic replace)
  local tmp="$TERMUX_DIR/.colors.properties.mld.$$"
  cp -- "$1" "$tmp"
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$2"
}

reload_termux() {
  if have_cmd termux-reload-settings && termux-reload-settings >/dev/null 2>&1; then
    log_ok "Termux settings reloaded."
    return 0
  fi
  log_warn "Could not reload Termux settings automatically."
  log_info "Manual: run 'termux-reload-settings', or fully close Termux (exit, then swipe it away) and reopen it."
}

scope_note() {
  log_info "Only Termux's own terminal colours changed. The Android system theme, the XFCE desktop and your VNC viewer app are NOT affected."
}

need_env() {
  if [ -z "${MLD_TERMUX_DIR:-}" ]; then
    mld_is_termux || die "This must run inside Termux."
  fi
}

cmd_apply() {
  local backup="" had=0
  need_env
  [ -r "$THEME_SRC" ] || die "Theme file not found: $THEME_SRC"
  if theme_is_applied; then
    log_info "The MobileLinux theme is already applied. Nothing to do."
    return 0
  fi
  if [ "$ASSUME_YES" != 1 ]; then
    log_info "This will replace ~/.termux/colors.properties (terminal colours only)."
    log_info "A backup of any existing file is saved first in: $BACKUP_DIR"
    mld_confirm_strict "Apply the MobileLinux Termux theme?" n || { log_info "Cancelled. Nothing was changed."; return 0; }
  fi
  mkdir -p "$TERMUX_DIR"
  if [ -f "$TARGET" ]; then
    backup="$(make_backup "$TARGET" "")"
    had=1
    log_ok "Backed up your current colours to: $backup"
  else
    log_info "No existing colors.properties - nothing to back up."
  fi
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" 2>/dev/null || true
  install_file "$THEME_SRC" "$TARGET"
  state_write "$had" "$backup" applied
  log_ok "MobileLinux theme installed."
  reload_termux
  scope_note
  log_info "Undo any time with: mld theme restore"
}

cmd_restore() {
  local had backup status safety
  need_env
  [ -f "$STATE" ] || die "No MobileLinux theme record found ($STATE). Nothing to restore."
  had="$(state_get HAD_ORIGINAL)"
  backup="$(state_get BACKUP)"
  status="$(state_get STATUS)"
  if [ "$status" = restored ]; then
    log_info "The previous theme was already restored."
    return 0
  fi
  if [ "$had" = 1 ]; then
    case "$backup" in
      "$BACKUP_DIR"/colors.properties.*) ;;
      *) die "Backup path in the state file is not inside $BACKUP_DIR; refusing to use it." ;;
    esac
    [ -f "$backup" ] || die "Backup file is missing: $backup"
  fi
  if [ -f "$TARGET" ] && ! theme_is_applied; then
    log_warn "colors.properties was changed after the theme was applied."
    safety="$(make_backup "$TARGET" "before-restore-")"
    log_ok "Saved your current file as: $safety"
    if [ "$ASSUME_YES" != 1 ]; then
      mld_confirm_strict "Replace the current file with the original backup?" n || { log_info "Cancelled."; return 0; }
    fi
  fi
  if [ "$had" = 1 ]; then
    install_file "$backup" "$TARGET"
    log_ok "Restored your previous colors.properties from: $backup"
  else
    rm -f -- "$TARGET"
    log_ok "Removed the theme file (you had no colors.properties before)."
  fi
  state_write "$had" "$backup" restored
  reload_termux
}

cmd_status() {
  if theme_is_applied; then
    log_ok "MobileLinux theme: applied"
    return 0
  fi
  log_info "MobileLinux theme: not applied"
  return 1
}

cmd_backups() {
  if [ -d "$BACKUP_DIR" ]; then
    log_info "Backups in $BACKUP_DIR:"
    ls -1 "$BACKUP_DIR" 2>/dev/null || true
  else
    log_info "No backups yet ($BACKUP_DIR does not exist)."
  fi
}

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}"; }

main() {
  local cmd="${1:-status}" a
  if [ $# -gt 0 ]; then shift; fi
  for a in "$@"; do
    case "$a" in
      -y|--yes) ASSUME_YES=1 ;;
      *) die "Unknown option: $a" ;;
    esac
  done
  case "$cmd" in
    apply)   cmd_apply ;;
    restore) cmd_restore ;;
    status)  cmd_status || exit 1 ;;
    backups) cmd_backups ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
