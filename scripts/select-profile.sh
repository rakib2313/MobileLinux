#!/usr/bin/env bash
# Show or select the hardware profile. RUN IN: Termux (host).
# Usage: bash scripts/select-profile.sh [show|list|auto|low|mid|high]
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
ml_install_traps
ml_load_config

show_profiles() {
  local p
  for p in "${ML_PROFILES[@]}"; do
    (
      ml_load_env_file "$ML_ROOT/configs/profiles/$p.conf" '^PROFILE_' 1
      printf '  %-5s %s\n' "$p" "${PROFILE_DESCRIPTION:-}"
    )
  done
}

mem="$(ml_detect_mem_mb)"
case "${1:-show}" in
  show)
    echo "Detected RAM: ${mem} MiB (best effort; 0 = unknown)"
    echo "Automatic recommendation: $(ml_recommend_profile)   (detection can be wrong; override it if needed)"
    echo "Configured: ${ML_PROFILE}   (config file: $ML_CONFIG_FILE)"
    echo "Available profiles:"; show_profiles
    echo "Change with: bash scripts/select-profile.sh low|mid|high|auto"
    ;;
  list|-l) show_profiles ;;
  auto|low|mid|high)
    ml_config_set ML_PROFILE "$1"
    ml_ok "Profile set to '$1' in $ML_CONFIG_FILE"
    ML_PROFILE="$1"
    ml_resolve_profile
    ml_info "Effective profile: $ML_PROFILE_RESOLVED"
    ml_info "Apply resolution/window settings: bash scripts/setup-vnc.sh restart"
    ml_info "Apply package changes (extra apps): bash scripts/install.sh --skip-upgrade"
    ;;
  *) ml_die "Unknown argument '$1'. Use: show | list | auto | low | mid | high" 2 ;;
esac
