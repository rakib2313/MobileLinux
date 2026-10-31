#!/usr/bin/env bash
# Optional AI helper (curl + jq). Works in Termux or in the Debian guest. NOTHING else in MobileLinux needs it.
#
# Usage:
#   bash scripts/ai-assistant.sh [-y] "your question"
#   cat main.py | bash scripts/ai-assistant.sh [-y] "explain this code"
#
# PRIVACY / COST: the prompt AND any piped input are sent over the network to the endpoint you configure.
# Do not send secrets or private code you are not willing to share with that provider. API calls may be
# billed by the provider. You need network access.
#
# Supported protocol (only one, deliberately): "openai-chat" = HTTP POST of JSON
#   {"model": "...", "messages": [{"role":"system"?...}, {"role":"user","content":"..."}], "max_tokens"?: N}
#   with header "Authorization: Bearer <key>", response read from .choices[0].message.content.
# Many providers/local servers offer a compatible endpoint, but NOT all do; check yours.
#
# Configuration (environment variables, or ~/.config/mobilelinux/ai.env with chmod 600; env wins):
#   AI_API_ENDPOINT   full URL of the chat-completions endpoint (https://, or http:// for localhost only)
#   AI_MODEL          model name (no default on purpose)
#   AI_API_KEY        API key (never put it in the URL; never commit it)
#   AI_API_FORMAT     must be "openai-chat" (default)
#   AI_ALLOW_NO_KEY   set to 1 for a local server that needs no key
#   AI_MAX_TOKENS     optional integer limit      AI_SYSTEM_PROMPT  optional system message
#   AI_TIMEOUT        seconds, default 120        AI_ASSUME_YES=1   same as -y (skip the confirmation)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
ml_install_traps

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

ASSUME_YES="${AI_ASSUME_YES:-0}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) ml_die "Unknown option: $1" 2 ;;
    *) break ;;
  esac
done
[[ $# -ge 1 ]] || { usage >&2; ml_die "Missing prompt." 2; }
PROMPT="$*"

ml_require curl jq
AI_CONFIG_FILE="${AI_CONFIG_FILE:-$ML_CONFIG_DIR/ai.env}"
if [[ -f "$AI_CONFIG_FILE" ]]; then
  perms="$(stat -c '%a' "$AI_CONFIG_FILE" 2>/dev/null || echo "")"
  if [[ -n "$perms" && "$perms" != 600 && "$perms" != 400 ]]; then
    ml_warn "$AI_CONFIG_FILE has permissions $perms; run: chmod 600 \"$AI_CONFIG_FILE\""
  fi
fi
ml_load_env_file "$AI_CONFIG_FILE" '^AI_'

: "${AI_API_FORMAT:=openai-chat}" "${AI_TIMEOUT:=120}"
[[ "$AI_API_FORMAT" == openai-chat ]] || ml_die "Unsupported AI_API_FORMAT '$AI_API_FORMAT' (only 'openai-chat' is implemented)."
[[ -n "${AI_API_ENDPOINT:-}" ]] || ml_die "AI_API_ENDPOINT is not set. See: bash scripts/ai-assistant.sh --help"
[[ -n "${AI_MODEL:-}" ]] || ml_die "AI_MODEL is not set. See: bash scripts/ai-assistant.sh --help"
[[ "$AI_TIMEOUT" =~ ^[0-9]+$ ]] || ml_die "AI_TIMEOUT must be an integer."
if [[ -n "${AI_MAX_TOKENS:-}" && ! "${AI_MAX_TOKENS}" =~ ^[0-9]+$ ]]; then
  ml_die "AI_MAX_TOKENS must be an integer."
fi
if [[ "${AI_ALLOW_NO_KEY:-0}" != 1 ]]; then
  [[ -n "${AI_API_KEY:-}" ]] || ml_die "AI_API_KEY is not set (or set AI_ALLOW_NO_KEY=1 for a keyless local server)."
  if [[ "$AI_API_KEY" == *$'\n'* || "$AI_API_KEY" == *'"'* || "$AI_API_KEY" == *'\'* ]]; then
    ml_die "AI_API_KEY contains characters that are not allowed (newline, quote or backslash)."
  fi
fi
if ! [[ "$AI_API_ENDPOINT" =~ ^https:// || "$AI_API_ENDPOINT" =~ ^http://(localhost|127\.0\.0\.1|\[::1\])([:/]|$) ]]; then
  ml_die "AI_API_ENDPOINT must start with https:// (plain http:// is accepted for localhost only)."
fi
host="${AI_API_ENDPOINT#*://}"
host="${host%%/*}"
host="${host##*@}"

content="$PROMPT"
if [[ ! -t 0 ]]; then
  stdin_data="$(cat)"
  if [[ -n "$stdin_data" ]]; then
    content="$PROMPT"$'\n\n'"$stdin_data"
  fi
fi

bytes="${#content}"
if [[ "$ASSUME_YES" != 1 ]]; then
  if [[ -t 0 ]]; then
    read -r -p "Send about $bytes characters to '$host' (model: $AI_MODEL)? [y/N] " ans
    [[ "$ans" == [yY] || "$ans" == [yY][eE][sS] ]] || ml_die "Cancelled. Nothing was sent." 1
  else
    ml_die "Input came from a pipe, so no confirmation is possible. Re-run with -y to confirm sending data to '$host'."
  fi
else
  ml_info "Sending about $bytes characters to '$host' (model: $AI_MODEL)."
fi

ml_mktemp REQ_FILE
ml_mktemp RESP_FILE
jq -n --arg model "$AI_MODEL" --arg sys "${AI_SYSTEM_PROMPT:-}" --arg user "$content" --arg mt "${AI_MAX_TOKENS:-}" '
  {model: $model,
   messages: ((if $sys != "" then [{role:"system", content:$sys}] else [] end) + [{role:"user", content:$user}])}
  | if $mt != "" then . + {max_tokens: ($mt | tonumber)} else . end' >"$REQ_FILE"

do_request() { # extra curl args via "$@"; the key is passed through a file descriptor, not argv
  curl --silent --show-error --max-time "$AI_TIMEOUT" --output "$RESP_FILE" --write-out '%{http_code}' \
    -H 'Content-Type: application/json' --data-binary @"$REQ_FILE" "$@" "$AI_API_ENDPOINT"
}

scrub() { # remove the key from anything we print
  local s="$1"
  if [[ -n "${AI_API_KEY:-}" ]]; then
    s="${s//"$AI_API_KEY"/[REDACTED]}"
  fi
  printf '%s' "$s"
}

curl_rc=0
if [[ "${AI_ALLOW_NO_KEY:-0}" == 1 ]]; then
  http_code="$(do_request)" || curl_rc=$?
else
  http_code="$(do_request --config <(printf 'header = "Authorization: Bearer %s"\n' "$AI_API_KEY"))" || curl_rc=$?
fi
if ((curl_rc != 0)); then
  ml_die "Network request to '$host' failed (curl exit $curl_rc). Check connectivity, endpoint and AI_TIMEOUT."
fi

if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
  msg="$(jq -r '.error.message // .error // .message // empty' "$RESP_FILE" 2>/dev/null | head -c 300 || true)"
  ml_die "Provider returned HTTP $http_code. ${msg:+Message: $(scrub "$msg")}"
fi

answer="$(jq -r '.choices[0].message.content // empty' "$RESP_FILE" 2>/dev/null || true)"
[[ -n "$answer" ]] || ml_die "The response did not contain .choices[0].message.content. Is your endpoint 'openai-chat' compatible?"
printf '%s\n' "$answer"
