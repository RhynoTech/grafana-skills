# Example HTTP service-health presets (committed, generic).
#
#   define_preset <name> <promql|logql> <query> [description]

define_preset "http/error-rate" promql \
  '100 * sum(rate(http_requests_total{status=~"5.."}[5m])) / clamp_min(sum(rate(http_requests_total[5m])), 1)' \
  "Overall 5xx error rate (%)"

define_preset "http/error-rate-by-route" promql \
  'sum by (route) (rate(http_requests_total{status=~"5.."}[5m]))' \
  "5xx rate broken down by route"

define_preset "http/latency-p90" promql \
  'histogram_quantile(0.90, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))' \
  "p90 request latency (seconds)"
