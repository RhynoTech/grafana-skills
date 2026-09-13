# Grafana Query Reference

Deeper detail behind the [SKILL.md](../SKILL.md) workflow: environment/auth
config, the preset and report-definition formats, query-authoring tips, and how
to read the JSON output. To *create* presets use the **author-preset** skill;
for report definitions use the **author-report** skill.

## Datasource configuration

The wrappers talk to Grafana's datasource proxy:

- PromQL → `api/datasources/proxy/uid/<prometheus-uid>/api/v1/query[_range]`
- LogQL → `api/datasources/proxy/uid/<loki-uid>/loki/api/v1/query_range`

Config comes from environment variables, usually populated from a gitignored
`.env` (see `.env.example`). Shell env vars override `.env`. Each Grafana
instance is a **named environment**; `<ENV>` below is the active environment name
uppercased with non-alphanumerics turned into `_` (so `us-east` → `US_EAST`).

| Variable | Purpose | Default |
| --- | --- | --- |
| `GRAFANA_ENV` | Active environment for this command | `GRAFANA_DEFAULT_ENV` → `prod` |
| `GRAFANA_DEFAULT_ENV` | Default environment when `GRAFANA_ENV` is unset | `prod` |
| `GRAFANA_<ENV>_BASE_URL` | Base URL for that environment | **required** |
| `GRAFANA_<ENV>_TOKEN` | API/service-account token (bearer auth; preferred) | — |
| `GRAFANA_<ENV>_COOKIE` | Session cookie header (fallback auth) | — |
| `GRAFANA_<ENV>_PROMETHEUS_UID` | Prometheus datasource UID | `prometheus` |
| `GRAFANA_<ENV>_LOKI_UID` | Loki datasource UID | `loki` |
| `GRAFANA_BASE_URL` / `GRAFANA_TOKEN` / `GRAFANA_COOKIE` / `GRAFANA_PROMETHEUS_UID` / `GRAFANA_LOKI_UID` | Unprefixed fallbacks (handy for a single instance) | — |
| `GRAFANA_QUERY_ENV_FILE` | Path to the `.env` to load (`/dev/null` disables) | `.env` beside the scripts → `~/.config/grafana-tools/.env` |
| `GRAFANA_QUERY_PRESETS_DIR` | Directory of preset `*.sh` files | `presets/local` → `~/.config/grafana-tools/presets` → `presets/example` |
| `GRAFANA_QUERY_REPORTS_DIR` | Directory of report `*.json` definitions | `reports/local` → `~/.config/grafana-tools/reports` → `reports/example` |
| `CURL_BIN` | Override the curl executable (used by the test suite) | `curl` |

`sweep.sh` takes no configuration of its own — it shells out to `promql.sh` and
`logql.sh`, so it inherits the active environment and credentials.

Auth precedence per environment: a **token** (`Authorization: Bearer`) is used if
present, otherwise the **cookie** header; if neither is set the scripts exit with
a clear message. A prefixed `GRAFANA_<ENV>_*` value wins over the unprefixed one.

## Time windows: seconds vs nanoseconds

This trips people up constantly:

- **PromQL** (`promql.sh`): `--start`/`--end` are **Unix epoch seconds**.
- **LogQL** (`logql.sh`): `--start`/`--end` are **nanoseconds**;
  `--since` is a relative lookback in **seconds**.
- **`sweep.sh`**: `--start`/`--end` are **seconds for both datasources** — it
  converts for Loki itself. `--since` takes a duration (`6h`, `7d`), not a
  bare number of seconds.

Prefer `--since` for Loki unless you need an exact historical window. For
PromQL ranges, generate bounds with `date`:

```bash
end=$(date +%s); start=$((end - 3600))   # last hour
```

For anything longer than a few hours, use `sweep.sh` rather than a single wide
window — see [windows-and-limits.md](windows-and-limits.md).

## How the scripts report failure

`run_grafana_query` in `common.sh` uses curl's `--fail-with-body`, so the
datasource's own error text survives instead of being replaced by a bare exit
code. Failures are classified before they reach you:

| HTTP | What you get on stderr | What it means |
| --- | --- | --- |
| `200` | (JSON on stdout) | Success. |
| `3xx`, `401`, `403` | "auth failed … cookie has almost certainly expired" | A setup step. No query change helps. |
| `502`, `503`, `504` | "too expensive to finish … narrow the window" | A cost ceiling, **not** an absence of data. |
| other | the datasource's own error body | e.g. "exceeded maximum resolution of 11,000 points". |

stdout stays clean on failure, so a `jq` pipeline sees empty input rather than an
error document — and the script exits non-zero in every non-`200` case.

## Preset files (`presets/`)

`incident.sh` sources every `*.sh` in the active presets directory — the first
of `presets/local/`, `~/.config/grafana-tools/presets/`, `presets/example/`
that contains files (or a directory named by `GRAFANA_QUERY_PRESETS_DIR`). Each
file is one group; drop in a new file and it's picked up. Define presets with:

```bash
define_preset <name> <promql|logql> <query> [description]
```

- **`<name>`** — identifier for `incident.sh run` (convention: `group/name`).
- **`<promql|logql>`** — which datasource. The query string is passed verbatim
  to `promql.sh` / `logql.sh`.
- Options passed to `incident.sh run` (`--start`/`--end`/`--step`, `--since`,
  `--limit`) flow through to the underlying script.

Committed example groups: `kafka/*`, `http/*`, `queue/*`. A team's real presets
live in `presets/local/*.sh` (gitignored) and can be grouped however fits. Always
run `incident.sh list` for the authoritative set.

## Report definitions (`reports/`)

`report.sh --config <name>` (default `overview`) loads the first of
`reports/local/<name>.json`, `~/.config/grafana-tools/reports/<name>.json`,
`reports/example/<name>.json` (or a directory named by
`GRAFANA_QUERY_REPORTS_DIR`). A definition is JSON with a `title` and an ordered
list of `sections`. Every query supports tokens substituted at run time —
**PromQL braces `{…}` are left untouched, so no escaping is needed**:

- `__W__` — window length in hours (`24` for daily columns, `days*24` for the
  window total)
- `__TS__` — epoch seconds for the PromQL `@`-modifier

Each section has a `kind` and a `title`:

- **`scalar`** — `metrics: [{label, query, fmt?}]`. Each metric is summed and
  shown per day plus a window total. `fmt` ∈ `int` (default) | `float` | `pct` |
  `seconds`. Express a ratio (e.g. error rate %) as a single query with
  `fmt: "pct"`.
- **`range_max`** — `metrics: [{label, query, fmt?}]`. Each query is a range
  query; the section shows the per-day peak. Good for CPU/memory/latency maxes.
  (These queries use their own `[5m]` windows and ignore `__W__`/`__TS__`.)
- **`topn`** — a single `query` (a `by (...)` aggregation); shows the top rows
  by value. Options: `top` (default 10), `item_label`, `fmt`, and `csv: true`
  to also write `<prefix>-<section-slug>.csv`.

Outputs: `<prefix>.md`, `<prefix>.json` (all computed section data), and one CSV
per `topn` section flagged `csv`. See `reports/example/overview.json` for a
complete generic example.

## Authoring custom queries

When no preset fits, author directly. Useful patterns:

**PromQL**
- Aggregate then inspect labels: `sum by (label) (rate(metric_total[5m]))`.
- Error *rate* not just count: divide error rate by total rate, and
  `clamp_min(denominator, 1)` to avoid divide-by-zero noise.
- Percentiles from histograms:
  `histogram_quantile(0.90, sum by (le, ...) (rate(metric_bucket[5m])))`.

**LogQL**
- Selector first (`{app="…"}`), then filter lines: `|=` substring, `|~` regex,
  `!=` / `!~` to exclude.
- Case-insensitive regex: `|~ "(?i)error|timeout"`.
- Keep `--limit` modest while exploring; raise it once the selector is tight.

## Reading the JSON output

Scripts emit raw Grafana JSON. Common `jq` recipes:

```bash
# PromQL instant: label set + value per series
… | jq -r '.data.result[] | "\(.metric) \(.value[1])"'

# PromQL range: last value of each series
… | jq -r '.data.result[] | "\(.metric) \(.values[-1][1])"'

# LogQL: flatten to "timestamp  logline", newest first
… | jq -r '.data.result[].values[] | "\(.[0])  \(.[1])"' | sort -r | head

# Just confirm success
… | jq -r '.status'
```

If `jq` reports the input isn't JSON, the script likely printed an error to
stderr (missing base URL / credentials, auth failure, bad query) — read that
message.
