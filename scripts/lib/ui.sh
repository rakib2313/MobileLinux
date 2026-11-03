#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# ui.sh - MobileLinux terminal UI (sourced after common.sh)
#   logo, numbered phases, spinner (run_step), required/optional steps,
#   result table, error screen, final summary.
# Safety rules: animation only on a real terminal; the spinner never hides
# errors (failed steps print their last log lines); child processes are
# killed on exit/interrupt; the exit code of the monitored command is kept.
# =============================================================================

if [ -n "${MLD_UI_LOADED:-}" ]; then
  return 0
fi
MLD_UI_LOADED=1

UI_PHASE_NO=0
UI_PHASE_TOTAL="${UI_PHASE_TOTAL:-8}"
UI_PHASE_NAME="startup"
UI_ENV="termux"
UI_LAST_OP=""
UI_LAST_CMD=""
UI_LAST_RC=""
UI_HINT=""
UI_OPTIONAL=0
UI_ERROR_SHOWN=0
UI_ERROR_SCREEN="${UI_ERROR_SCREEN:-0}"
UI_STEP_PID=""
UI_CURSOR_HIDDEN=0
UI_INSTALL_CMD="${UI_INSTALL_CMD:-bash scripts/install.sh}"
UI_DIAG_CMD="${UI_DIAG_CMD:-bash scripts/diagnose.sh}"
RES_NAMES=(); RES_STATES=(); RES_NOTES=(); RES_FIX=()

ui_animate() {
  [ "${MLD_NO_ANIM:-0}" != "1" ] && [ -t 2 ] && [ "${TERM:-dumb}" != "dumb" ]
}

ui_cols() {
  local c="${COLUMNS:-}"
  if [ -z "$c" ] && have_cmd tput; then
    c="$(tput cols 2>/dev/null || true)"
  fi
  case "$c" in
    ''|*[!0-9]*) c=60 ;;
  esac
  if [ "$c" -lt 20 ]; then c=20; fi
  echo "$c"
}

ui_wrap() {
  local w
  w=$(( $(ui_cols) - 4 ))
  if have_cmd fold; then fold -s -w "$w"; else cat; fi
}
ui_note() { printf '%s\n' "$*" | ui_wrap | sed 's/^/  /' >&2; }
ui_kv()   { printf '  %s%-9s%s %s\n' "$C_DIM" "$1" "$C_RESET" "$2" >&2; }
ui_env()  { UI_ENV="$1"; }
mld_hint() { UI_HINT="$*"; }

ui_rule() {
  local n i
  n=$(( $(ui_cols) - 4 ))
  if [ "$n" -gt 36 ]; then n=36; fi
  printf '  %s' "$C_DIM" >&2
  for ((i = 0; i < n; i++)); do printf '%s' "$G_RULE" >&2; done
  printf '%s\n' "$C_RESET" >&2
}

_ui_block() { # colour ; text on stdin
  local col="$1" line delay=0
  if ui_animate; then delay=0.03; fi
  while IFS= read -r line; do
    printf '  %s%s%s\n' "$col" "$line" "$C_RESET" >&2
    if [ "$delay" != 0 ]; then sleep "$delay"; fi
  done
}

# Plain-text logo (about 28 columns). Falls back to a one-line title on very
# narrow terminals. Short reveal animation only on interactive terminals.
ui_logo() {
  printf '\n' >&2
  if [ "$(ui_cols)" -lt 34 ]; then
    printf '  %s[ MobileLinux ]%s v%s\n' "${C_BOLD}${C_CYAN}" "$C_RESET" "$MLD_VERSION" >&2
    return 0
  fi
  _ui_block "${C_BOLD}${C_CYAN}" <<'EOF'
 __  __       _     _ _
|  \/  | ___ | |__ (_) | ___
| |\/| |/ _ \| '_ \| | |/ _ \
| |  | | (_) | |_) | | |  __/
|_|  |_|\___/|_.__/|_|_|\___|
EOF
  _ui_block "${C_BOLD}${C_GREEN}" <<'EOF'
 _     _
| |   (_)_ __  _   ___  __
| |   | | '_ \| | | \ \/ /
| |___| | | | | |_| |>  <
|_____|_|_| |_|\__,_/_/\_\
EOF
}

ui_welcome() {
  ui_logo
  printf '  %sLinux desktop + dev tools on Android%s  v%s\n' "$C_BOLD" "$C_RESET" "$MLD_VERSION" >&2
  printf '  %sTermux + PRoot Debian + XFCE + VNC%s\n\n' "$C_DIM" "$C_RESET" >&2
  ui_note "Welcome! This installer checks your phone, sets up Debian inside Termux, then installs a desktop (XFCE + TigerVNC) and web-dev tools. It asks before optional extras."
  ui_note "Expect 10-30+ minutes and 3-5 GB of storage. Keep Termux open, the screen on, and the phone charging."
  ui_note "Unofficial project: not affiliated with Linux, Debian, Termux or Android."
  ui_kv "Log" "$MLD_LOG_FILE"
}

ui_phase() { # name [termux|debian]
  local name="$1" i bar=""
  UI_PHASE_NO=$((UI_PHASE_NO + 1))
  UI_PHASE_NAME="$name"
  UI_ENV="${2:-termux}"
  for ((i = 1; i <= UI_PHASE_TOTAL; i++)); do
    if [ "$i" -le "$UI_PHASE_NO" ]; then bar="${bar}="; else bar="${bar}-"; fi
  done
  printf '\n%s[%d/%d] %s%s\n' "${C_BOLD}${C_CYAN}" "$UI_PHASE_NO" "$UI_PHASE_TOTAL" "$name" "$C_RESET" >&2
  printf '  %s[%s]%s\n' "$C_DIM" "$bar" "$C_RESET" >&2
  mld_log_raw "[PHASE] ${UI_PHASE_NO}/${UI_PHASE_TOTAL} ${name} (${UI_ENV})"
}

ui_where() {
  case "$UI_ENV" in
    debian) echo "Debian guest (inside PRoot)" ;;
    *)      echo "Termux (Android host)" ;;
  esac
}

# ---- cleanup / exit hooks ----------------------------------------------------
ui_cleanup() {
  if [ -n "${UI_STEP_PID:-}" ]; then
    mld_kill_tree "$UI_STEP_PID" TERM
    sleep 1
    mld_kill_tree "$UI_STEP_PID" KILL
    UI_STEP_PID=""
  fi
  if [ "$UI_CURSOR_HIDDEN" = 1 ]; then
    printf '\r\033[K\033[?25h' >&2
    UI_CURSOR_HIDDEN=0
  fi
}

ui_on_exit() { # rc
  local rc="$1"
  ui_cleanup
  if [ "$rc" -ne 0 ] && [ "$UI_ERROR_SHOWN" != 1 ] && [ "$UI_ERROR_SCREEN" = 1 ]; then
    ui_error_screen "$rc"
  fi
}

# ---- steps ---------------------------------------------------------------------
# run_step "message" cmd...
#   Output goes to the log; a spinner shows elapsed time and the last log line.
#   stdin is /dev/null (commands must be non-interactive). Stall warning after
#   MLD_STALL_SECS (900), hard limit MLD_STEP_TIMEOUT (7200; 0 disables). MLD_VERBOSE=1 (or no
#   writable log) streams the output live. Returns the command's own exit code.
run_step() {
  local msg="$1" rc=0 i=0 ticks=0 start="$SECONDS" elapsed=0 mode=quiet
  local size last_size last_change limit="${MLD_STEP_TIMEOUT:-7200}" stall="${MLD_STALL_SECS:-900}"
  local timed_out=0 cols=80 line="" rest nframes frame opt="${UI_OPTIONAL:-0}" log_start=0
  shift
  UI_LAST_OP="$msg"
  UI_LAST_CMD="$(printf '%s ' "$@" | mld_redact)"
  UI_LAST_RC=""
  mld_log_raw "=== ${msg} ==="
  mld_log_raw "cmd: ${UI_LAST_CMD}"
  log_start="$(mld_file_size "$MLD_LOG_FILE")"
  if [ "${MLD_VERBOSE:-0}" = "1" ] || [ "$MLD_LOG_FILE" = "/dev/null" ]; then
    mode=live
  elif ui_animate; then
    mode=spin
  fi
  case "$mode" in
    live)
      log_info "$msg"
      ( trap - ERR; "$@" 2>&1 </dev/null | tee -a "$MLD_LOG_FILE" >&2 ) &
      ;;
    spin)
      ( trap - ERR; "$@" ) </dev/null >>"$MLD_LOG_FILE" 2>&1 &
      ;;
    *)
      log_info "${msg} ..."
      ( trap - ERR; "$@" ) </dev/null >>"$MLD_LOG_FILE" 2>&1 &
      ;;
  esac
  UI_STEP_PID=$!
  last_size="$(mld_file_size "$MLD_LOG_FILE")"
  last_change="$SECONDS"
  nframes=${#SPIN_FRAMES[@]}
  if [ "$mode" = spin ]; then
    cols="$(ui_cols)"
    printf '\033[?25l' >&2
    UI_CURSOR_HIDDEN=1
  fi
  while kill -0 "$UI_STEP_PID" 2>/dev/null; do
    sleep 0.2
    ticks=$((ticks + 1))
    elapsed=$((SECONDS - start))
    if [ $((ticks % 5)) -eq 0 ]; then
      size="$(mld_file_size "$MLD_LOG_FILE")"
      if [ "$size" != "$last_size" ]; then
        last_size="$size"
        last_change="$SECONDS"
      fi
      if [ "$mode" = spin ]; then
        line="$(tail -c 300 "$MLD_LOG_FILE" 2>/dev/null | tr '\r' '\n' | tail -n 1 | tr -c '[:print:]' ' ' || true)"
      fi
      if [ $((SECONDS - last_change)) -ge "$stall" ]; then
        if [ "$mode" = spin ]; then printf '\r\033[K' >&2; fi
        log_warn "No new output for $((stall / 60)) min during '${msg}' (a very slow download looks the same)."
        log_warn "Watch live from a second Termux session: tail -f ${MLD_LOG_FILE}"
        log_warn "If it never moves: press Ctrl+C, check your connection, then re-run the installer (finished steps are reused)."
        last_size="$(mld_file_size "$MLD_LOG_FILE")"
        last_change="$SECONDS"
      fi
      if [ "$limit" -gt 0 ] && [ "$elapsed" -ge "$limit" ]; then
        timed_out=1
        break
      fi
    fi
    if [ "$mode" = spin ]; then
      i=$(( (i + 1) % nframes ))
      frame="${SPIN_FRAMES[$i]}"
      rest="$(printf '%s [%02d:%02d] %s' "$msg" $((elapsed / 60)) $((elapsed % 60)) "$line")"
      printf '\r\033[K  %s%s%s %s' "$C_CYAN" "$frame" "$C_RESET" "${rest:0:$((cols - 5))}" >&2
    fi
  done
  if [ "$timed_out" -eq 1 ]; then
    if [ "$mode" = spin ]; then printf '\r\033[K' >&2; fi
    log_err "'${msg}' ran longer than ${limit}s - stopping it."
    mld_kill_tree "$UI_STEP_PID" TERM
    sleep 3
    mld_kill_tree "$UI_STEP_PID" KILL
  fi
  wait "$UI_STEP_PID" 2>/dev/null || rc=$?
  UI_STEP_PID=""
  if [ "$timed_out" -eq 1 ]; then rc=124; fi
  if [ "$mode" = spin ]; then
    printf '\r\033[K\033[?25h' >&2
    UI_CURSOR_HIDDEN=0
  fi
  if [ "$rc" -eq 0 ]; then
    log_ok "${msg} ($((SECONDS - start))s)"
    return 0
  fi
  UI_LAST_RC="$rc"
  if [ "$opt" = 1 ]; then
    log_warn "${msg} failed (exit ${rc}) - optional, continuing."
  else
    log_err "${msg} failed (exit ${rc})."
  fi
  if [ "$mode" != live ] && [ "$MLD_LOG_FILE" != "/dev/null" ]; then
    printf '  %sLast log lines:%s\n' "$C_DIM" "$C_RESET" >&2
    tail -c +$((log_start + 1)) "$MLD_LOG_FILE" 2>/dev/null | tail -n 15 | mld_redact | sed 's/^/    | /' >&2 || true
  fi
  return "$rc"
}

# Required step: a failure stops the installer (the error screen is shown on exit).
step_required() { # message cmd...
  local rc=0
  UI_OPTIONAL=0
  run_step "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then exit "$rc"; fi
  return 0
}

# Optional step: a failure is recorded and reported in the summary, not fatal.
step_optional() { # message how-to-fix-later cmd...
  local msg="$1" fix="$2" rc=0
  shift 2
  UI_OPTIONAL=1
  run_step "$msg" "$@" || rc=$?
  UI_OPTIONAL=0
  if [ "$rc" -ne 0 ]; then
    ui_result "$msg" warn "failed (exit ${rc})" "$fix"
  fi
  return 0
}

# Interactive command (prompts must stay visible): runs in the foreground, no spinner.
run_interactive() { # message cmd...
  local msg="$1" rc=0
  shift
  UI_LAST_OP="$msg"
  UI_LAST_CMD="$(printf '%s ' "$@" | mld_redact)"
  mld_log_raw "=== ${msg} (interactive) ==="
  log_info "$msg"
  "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    UI_LAST_RC="$rc"
    log_err "${msg} failed (exit ${rc})."
    return "$rc"
  fi
  log_ok "$msg"
}

interactive_required() {
  local rc=0
  run_interactive "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then exit "$rc"; fi
  return 0
}

# ---- results ---------------------------------------------------------------------
ui_result() { # name state(ok|warn|skip|fail) note [fix]
  local i
  for i in "${!RES_NAMES[@]}"; do
    if [ "${RES_NAMES[$i]}" = "$1" ]; then
      RES_STATES[i]="$2"; RES_NOTES[i]="${3:-}"; RES_FIX[i]="${4:-}"
      return 0
    fi
  done
  RES_NAMES+=("$1"); RES_STATES+=("$2"); RES_NOTES+=("${3:-}"); RES_FIX+=("${4:-}")
}

ui_count_state() { # state
  local i n=0
  for i in "${!RES_STATES[@]}"; do
    if [ "${RES_STATES[$i]}" = "$1" ]; then n=$((n + 1)); fi
  done
  echo "$n"
}

ui_read_status() { # file written by mld_status in the guest
  local f="$1" tag name state note fix
  [ -r "$f" ] || return 0
  while IFS='|' read -r tag name state note fix || [ -n "$tag" ]; do
    if [ "$tag" = STATUS ]; then
      ui_result "$name" "$state" "$note" "$fix"
    fi
  done <"$f"
}

_ui_result_line() { # glyph colour name note
  printf '  %s%s%s %s' "$2" "$1" "$C_RESET" "$3" >&2
  if [ -n "$4" ]; then printf ' %s(%s)%s' "$C_DIM" "$4" "$C_RESET" >&2; fi
  printf '\n' >&2
}

ui_summary_results() {
  local i okline="" n_ok=0 st
  for i in "${!RES_NAMES[@]}"; do
    if [ "${RES_STATES[$i]}" = ok ]; then
      n_ok=$((n_ok + 1))
      okline="${okline:+$okline, }${RES_NAMES[$i]}"
    fi
  done
  if [ "$n_ok" -gt 0 ]; then
    printf '\n  %s%s %d checks passed%s\n' "$C_GREEN" "$G_OK" "$n_ok" "$C_RESET" >&2
    printf '%s\n' "$okline" | ui_wrap | sed "s/^/    /" >&2
  fi
  for st in fail warn skip; do
    if [ "$(ui_count_state "$st")" -eq 0 ]; then continue; fi
    case "$st" in
      fail) printf '\n  %sREQUIRED - needs attention:%s\n' "${C_BOLD}${C_RED}" "$C_RESET" >&2 ;;
      warn) printf '\n  %sOPTIONAL - failed (core install still usable):%s\n' "${C_BOLD}${C_YELLOW}" "$C_RESET" >&2 ;;
      skip) printf '\n  %sOPTIONAL - skipped:%s\n' "${C_BOLD}${C_BLUE}" "$C_RESET" >&2 ;;
    esac
    for i in "${!RES_NAMES[@]}"; do
      if [ "${RES_STATES[$i]}" != "$st" ]; then continue; fi
      case "$st" in
        fail) _ui_result_line "$G_FAIL" "$C_RED" "${RES_NAMES[$i]}" "${RES_NOTES[$i]}" ;;
        warn) _ui_result_line "$G_WARN" "$C_YELLOW" "${RES_NAMES[$i]}" "${RES_NOTES[$i]}" ;;
        skip) _ui_result_line "$G_SKIP" "$C_BLUE" "${RES_NAMES[$i]}" "${RES_NOTES[$i]}" ;;
      esac
      if [ -n "${RES_FIX[$i]}" ]; then
        printf '%s\n' "later: ${RES_FIX[$i]}" | ui_wrap | sed 's/^/      /' >&2
      fi
    done
  done
}

# ---- error screen ----------------------------------------------------------------
ui_error_screen() { # rc
  local rc="${1:-1}"
  UI_ERROR_SHOWN=1
  if [ "$rc" -eq 130 ]; then
    printf '\n  %s%s Interrupted.%s Nothing was deleted. Re-run to resume: %s\n' "$C_YELLOW" "$G_WARN" "$C_RESET" "$UI_INSTALL_CMD" >&2
    return 0
  fi
  printf '\n%s' "${C_BOLD}${C_RED}" >&2
  printf '  %s Installation stopped%s\n' "$G_FAIL" "$C_RESET" >&2
  ui_rule
  ui_kv "Phase" "[${UI_PHASE_NO}/${UI_PHASE_TOTAL}] ${UI_PHASE_NAME}"
  ui_kv "Where" "$(ui_where)"
  if [ -n "$MLD_LAST_ERROR" ]; then ui_kv "Reason" "$MLD_LAST_ERROR"; fi
  if [ -n "$UI_LAST_OP" ]; then ui_kv "Step" "$UI_LAST_OP"; fi
  if [ -n "$UI_LAST_CMD" ] && [ -n "$UI_LAST_RC" ]; then ui_kv "Command" "$(printf '%s' "$UI_LAST_CMD" | cut -c1-120)"; fi
  ui_kv "Exit code" "${UI_LAST_RC:-$rc}"
  ui_kv "Log" "$MLD_LOG_FILE"
  ui_rule
  printf '  %sWhat to do next%s\n' "$C_BOLD" "$C_RESET" >&2
  if [ -n "$UI_HINT" ]; then ui_note "* ${UI_HINT}"; fi
  if [ "${UI_LAST_RC:-$rc}" = "124" ]; then
    ui_note "* The step timed out. Check your connection, then re-run."
  fi
  case "$UI_ENV" in
    debian)
      ui_note "* The error happened inside Debian (PRoot). Re-run the installer; the package state is repaired automatically."
      ui_note "* To look around: proot-distro login debian"
      ;;
    *)
      ui_note "* The error happened in Termux. Check internet access and free storage (3 GB minimum), then re-run."
      ;;
  esac
  ui_note "* Re-run (finished steps are reused): ${UI_INSTALL_CMD}"
  ui_note "* Last log lines: tail -n 40 ${MLD_LOG_FILE}"
  ui_note "* Diagnostics (nothing is uploaded): ${UI_DIAG_CMD} --log"
  ui_note "* Before sharing a log, read it and remove anything private (see README: Reporting an issue)."
  ui_note "Nothing was deleted: Debian and your files are untouched."
}

# ---- final summary ---------------------------------------------------------------
ui_summary() { # extra lines are printed by the caller
  ui_logo
  printf '\n  %s%s MobileLinux installation complete%s\n' "${C_BOLD}${C_GREEN}" "$G_OK" "$C_RESET" >&2
  ui_rule
  ui_summary_results
}
