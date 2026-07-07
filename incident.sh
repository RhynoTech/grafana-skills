#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# incident.sh is a generic preset runner. The presets themselves (names, target
# datasource, and query bodies) live in separate files, grouped one file per
# concern, so you can keep your own site-specific queries without editing this
# engine. Every *.sh in the active presets directory is loaded:
#
#   1. $GRAFANA_QUERY_PRESETS_DIR, if set
#   2. presets/local/  next to this script (gitignored — your team's real presets)
#   3. ~/.config/grafana-tools/presets/ (survives plugin reinstalls/updates —
#      the recommended location when installed as a Claude Code plugin)
#   4. presets/example/ (committed generic examples; the fallback)
#
# A preset file defines presets by calling `define_preset`:
#   define_preset <name> <promql|logql> <query> [description]

PRESET_NAMES=()
PRESET_TYPES=()
PRESET_QUERIES=()
PRESET_DESCS=()

define_preset() {
  PRESET_NAMES+=("$1")
  PRESET_TYPES+=("$2")
  PRESET_QUERIES+=("$3")
  PRESET_DESCS+=("${4:-}")
}

# Directory contains at least one *.sh file?
_dir_has_presets() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  local f
  for f in "$dir"/*.sh; do
    [[ -e "$f" ]] && return 0
  done
  return 1
}

presets_dir() {
  local config_presets="${XDG_CONFIG_HOME:-$HOME/.config}/grafana-tools/presets"
  if [[ -n "${GRAFANA_QUERY_PRESETS_DIR:-}" ]]; then
    printf '%s\n' "$GRAFANA_QUERY_PRESETS_DIR"
  elif _dir_has_presets "$SCRIPT_DIR/presets/local"; then
    printf '%s\n' "$SCRIPT_DIR/presets/local"
  elif _dir_has_presets "$config_presets"; then
    printf '%s\n' "$config_presets"
  else
    printf '%s\n' "$SCRIPT_DIR/presets/example"
  fi
}

load_presets() {
  local dir
  dir="$(presets_dir)"
  if ! _dir_has_presets "$dir"; then
    printf 'No preset files (*.sh) found in: %s\n' "$dir" >&2
    exit 1
  fi
  local file
  for file in "$dir"/*.sh; do
    # shellcheck source=/dev/null
    source "$file"
  done
}

usage() {
  cat <<'EOF'
Usage:
  incident.sh list                     List available presets
  incident.sh run <preset> [options]   Run a preset; options pass through to
                                        promql.sh / logql.sh (e.g. --start,
                                        --end, --step, --since, --limit)

Presets load from presets/local/*.sh (your team's, gitignored) if present, then
~/.config/grafana-tools/presets/*.sh, otherwise presets/example/*.sh. Point
GRAFANA_QUERY_PRESETS_DIR at any directory to override. Run `incident.sh list`
for the available preset names.
EOF
}

list_presets() {
  local i
  for i in "${!PRESET_NAMES[@]}"; do
    if [[ -n "${PRESET_DESCS[$i]}" ]]; then
      printf '%s\t%s\n' "${PRESET_NAMES[$i]}" "${PRESET_DESCS[$i]}"
    else
      printf '%s\n' "${PRESET_NAMES[$i]}"
    fi
  done
}

run_preset() {
  local preset="$1"
  shift

  local i
  for i in "${!PRESET_NAMES[@]}"; do
    if [[ "${PRESET_NAMES[$i]}" == "$preset" ]]; then
      case "${PRESET_TYPES[$i]}" in
        promql) exec "$SCRIPT_DIR/promql.sh" "$@" "${PRESET_QUERIES[$i]}" ;;
        logql)  exec "$SCRIPT_DIR/logql.sh" "$@" "${PRESET_QUERIES[$i]}" ;;
        *)
          printf 'Preset "%s" has invalid type "%s" (expected promql or logql).\n' \
            "$preset" "${PRESET_TYPES[$i]}" >&2
          exit 1
          ;;
      esac
    fi
  done

  printf 'Unknown preset: %s\n' "$preset" >&2
  printf 'Run `incident.sh list` to see supported presets.\n' >&2
  exit 1
}

command="${1:-}"

case "$command" in
  list)
    load_presets
    list_presets
    ;;
  run)
    if [[ $# -lt 2 ]]; then
      usage >&2
      exit 1
    fi
    load_presets
    run_preset "$2" "${@:3}"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    printf 'Unknown command: %s\n' "$command" >&2
    usage >&2
    exit 1
    ;;
esac
