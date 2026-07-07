#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

datasource_uid="$(grafana_loki_uid)"
since_seconds="3600"
limit="100"
start=""
end=""

usage() {
  cat <<'EOF'
Usage: logql.sh [options] '<query>'

Options:
  --since <seconds>     Relative lookback window in seconds. Default: 3600.
  --start <nanoseconds> Absolute query start time in nanoseconds.
  --end <nanoseconds>   Absolute query end time in nanoseconds.
  --limit <count>       Maximum number of log streams to return. Default: 100.
  --help                Show this help text.

Environment (see .env.example):
  GRAFANA_ENV         Select the active environment (default "prod").
  GRAFANA_<ENV>_BASE_URL Grafana base URL for that environment (or GRAFANA_BASE_URL).
  GRAFANA_<ENV>_TOKEN    Grafana API/service-account token (bearer auth; preferred).
  GRAFANA_<ENV>_COOKIE   Grafana session cookie header (fallback auth).
  GRAFANA_LOKI_UID    Override the Loki datasource UID.
  CURL_BIN            Override the curl executable for testing.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      since_seconds="$2"
      shift 2
      ;;
    --start)
      start="$2"
      shift 2
      ;;
    --end)
      end="$2"
      shift 2
      ;;
    --limit)
      limit="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    --*)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

if [[ -n "$start" && -z "$end" ]]; then
  end="$(current_time_ns)"
fi

if [[ -z "$start" && -n "$end" ]]; then
  printf 'Use --start with --end, or use --since for a relative window.\n' >&2
  exit 1
fi

if [[ -z "$start" ]]; then
  end="$(current_time_ns)"
  start="$(offset_time_ns "$since_seconds")"
fi

query="$*"

run_grafana_query \
  "api/datasources/proxy/uid/$datasource_uid/loki/api/v1/query_range" \
  --data-urlencode "query=$query" \
  --data-urlencode "start=$start" \
  --data-urlencode "end=$end" \
  --data-urlencode "limit=$limit"
