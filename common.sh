#!/bin/bash

set -euo pipefail

readonly DEFAULT_GRAFANA_ENV="prod"

# ---------------------------------------------------------------------------
# Configuration is supplied entirely through environment variables so that no
# site-specific values (hostnames, tokens, cookies) are hard-coded in the repo.
# For convenience these can be populated from a .env file (see .env.example),
# which is gitignored. Real shell environment variables always take precedence
# over anything in .env.
#
# .env lookup order:
#   1. $GRAFANA_QUERY_ENV_FILE, if set (point at /dev/null to disable loading)
#   2. .env next to these scripts (repo checkout or installed plugin root)
#   3. ~/.config/grafana-tools/.env (survives plugin reinstalls/updates — the
#      recommended location when installed as a Claude Code plugin)
#
# Multiple Grafana instances are supported via named environments. The active
# environment is $GRAFANA_ENV (per command) -> $GRAFANA_DEFAULT_ENV (from .env)
# -> "prod". For an environment named E, config resolves from prefixed vars,
# falling back to the unprefixed var (handy for a single-instance setup):
#
#   GRAFANA_<E>_BASE_URL         -> GRAFANA_BASE_URL          (required)
#   GRAFANA_<E>_TOKEN            -> GRAFANA_TOKEN             (bearer; preferred)
#   GRAFANA_<E>_COOKIE          -> GRAFANA_COOKIE            (cookie header)
#   GRAFANA_<E>_PROMETHEUS_UID  -> GRAFANA_PROMETHEUS_UID    (default "prometheus")
#   GRAFANA_<E>_LOKI_UID        -> GRAFANA_LOKI_UID          (default "loki")
#
# Auth precedence: a token (Authorization: Bearer) is used if present, otherwise
# the cookie header. There are no cookie files.
# ---------------------------------------------------------------------------
load_env_file() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"      # left-trim leading whitespace
    line="${line#export }"                        # tolerate "export FOO=bar"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"          # trim key
    key="${key%"${key##*[![:space:]]}"}"
    [[ -z "$key" ]] && continue
    if [[ "$val" == \"*\" ]]; then
      val="${val:1:${#val}-2}"
    elif [[ "$val" == \'*\' ]]; then
      val="${val:1:${#val}-2}"
    fi
    # Shell environment wins: only apply .env values for vars not already set.
    [[ -z "${!key:-}" ]] && export "$key=$val"
  done < "$env_file"
}

# Per-user config directory: a durable home for .env, presets/, and reports/
# that plugin updates never touch.
grafana_config_dir() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/grafana-tools"
}

_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${GRAFANA_QUERY_ENV_FILE:-}" ]]; then
  load_env_file "$GRAFANA_QUERY_ENV_FILE"
elif [[ -f "$_common_dir/.env" ]]; then
  load_env_file "$_common_dir/.env"
else
  load_env_file "$(grafana_config_dir)/.env"
fi

# Name of the active environment.
grafana_env() {
  printf '%s\n' "${GRAFANA_ENV:-${GRAFANA_DEFAULT_ENV:-$DEFAULT_GRAFANA_ENV}}"
}

# Uppercased, underscore-normalized prefix for the active environment,
# e.g. "us-east" -> "US_EAST".
_grafana_env_prefix() {
  printf '%s' "$(grafana_env)" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_' | sed 's/_*$//'
}

# Resolve a per-environment setting: GRAFANA_<ENV>_<SUFFIX>, falling back to the
# unprefixed GRAFANA_<SUFFIX>. Usage: _grafana_setting BASE_URL
_grafana_setting() {
  local suffix="$1"
  local prefix scoped generic
  prefix="$(_grafana_env_prefix)"
  scoped="GRAFANA_${prefix}_${suffix}"
  generic="GRAFANA_${suffix}"
  if [[ -n "${!scoped:-}" ]]; then
    printf '%s' "${!scoped}"
  else
    printf '%s' "${!generic:-}"
  fi
}

grafana_base_url() {
  local url
  url="$(_grafana_setting BASE_URL)"
  if [[ -z "$url" ]]; then
    printf 'No Grafana base URL configured for env "%s".\n' "$(grafana_env)" >&2
    printf 'Set GRAFANA_%s_BASE_URL (or GRAFANA_BASE_URL), e.g. in a .env file. See .env.example.\n' \
      "$(_grafana_env_prefix)" >&2
    exit 1
  fi
  printf '%s\n' "${url%/}"
}

grafana_token() {
  _grafana_setting TOKEN
}

grafana_cookie() {
  _grafana_setting COOKIE
}

grafana_prometheus_uid() {
  local uid
  uid="$(_grafana_setting PROMETHEUS_UID)"
  printf '%s\n' "${uid:-prometheus}"
}

grafana_loki_uid() {
  local uid
  uid="$(_grafana_setting LOKI_UID)"
  printf '%s\n' "${uid:-loki}"
}

grafana_curl_bin() {
  printf '%s\n' "${CURL_BIN:-curl}"
}

run_grafana_query() {
  local datasource_path="$1"
  shift

  local curl_bin base_url token cookie
  curl_bin="$(grafana_curl_bin)"
  base_url="$(grafana_base_url)"
  token="$(grafana_token)"
  cookie="$(grafana_cookie)"

  if [[ -n "$token" ]]; then
    "$curl_bin" -fsS -G -H "Authorization: Bearer $token" "$@" "$base_url/$datasource_path"
  elif [[ -n "$cookie" ]]; then
    "$curl_bin" -fsS -G -H "Cookie: $cookie" "$@" "$base_url/$datasource_path"
  else
    printf 'No Grafana credentials configured for env "%s".\n' "$(grafana_env)" >&2
    printf 'Set GRAFANA_%s_TOKEN or GRAFANA_%s_COOKIE (or the unprefixed GRAFANA_TOKEN / GRAFANA_COOKIE) in your .env. See .env.example.\n' \
      "$(_grafana_env_prefix)" "$(_grafana_env_prefix)" >&2
    exit 1
  fi
}

current_time_ns() {
  python3 - <<'PY'
import time
print(int(time.time() * 1_000_000_000))
PY
}

offset_time_ns() {
  local seconds="$1"

  python3 - "$seconds" <<'PY'
import sys
import time

seconds = int(sys.argv[1])
print(int((time.time() - seconds) * 1_000_000_000))
PY
}
