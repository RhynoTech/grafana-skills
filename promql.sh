#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

datasource_uid="$(grafana_prometheus_uid)"
start=""
end=""
step="30s"

usage() {
  cat <<'EOF'
Usage: promql.sh [options] '<query>'

Options:
  --start <seconds>     Start time for a range query.
  --end <seconds>       End time for a range query.
  --step <duration>     Step for a range query. Default: 30s.
  --help                Show this help text.

Environment (see .env.example):
  GRAFANA_ENV            Select the active environment (default "prod").
  GRAFANA_<ENV>_BASE_URL Grafana base URL for that environment (or GRAFANA_BASE_URL).
  GRAFANA_<ENV>_TOKEN    Grafana API/service-account token (bearer auth; preferred).
  GRAFANA_<ENV>_COOKIE   Grafana session cookie header (fallback auth).
  GRAFANA_PROMETHEUS_UID Override the Prometheus datasource UID.
  CURL_BIN               Override the curl executable for testing.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start)
      start="$2"
      shift 2
      ;;
    --end)
      end="$2"
      shift 2
      ;;
    --step)
      step="$2"
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

query="$*"

if [[ -n "$start" || -n "$end" ]]; then
  if [[ -z "$start" || -z "$end" ]]; then
    printf 'Both --start and --end are required for a range query.\n' >&2
    exit 1
  fi

  run_grafana_query \
    "api/datasources/proxy/uid/$datasource_uid/api/v1/query_range" \
    --data-urlencode "query=$query" \
    --data-urlencode "start=$start" \
    --data-urlencode "end=$end" \
    --data-urlencode "step=$step"
  exit 0
fi

run_grafana_query \
  "api/datasources/proxy/uid/$datasource_uid/api/v1/query" \
  --data-urlencode "query=$query"
