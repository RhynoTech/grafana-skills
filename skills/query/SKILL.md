---
name: query
description: >-
  Query Grafana's Prometheus (PromQL) and Loki (LogQL) datasources and run
  canned incident presets straight from the shell, without cluster access. Use
  this whenever you are investigating a production issue, alert, or incident
  that touches metrics or logs — Kafka consumer lag, push-notification error
  rates, job/queue backlogs, error spikes, latency, service health, or any
  "what do the dashboards / metrics / logs say" question. Reach for it even when
  the user describes a symptom rather than the tool (e.g. "why is the
  high-error-rate alert firing", "consumer lag on the orders topic", "is the
  delivery queue backed up", "tail the api-server errors"), and whenever they
  mention Grafana, Prometheus, PromQL, Loki, LogQL, or pulling metrics/logs.
  Prefer these helpers over hand-rolled curl against Grafana.
---

# Grafana Query

Thin shell wrappers around Grafana's datasource proxy API. They authenticate
with a per-environment token or session cookie (from a gitignored `.env`), so
you can query one or more Grafana instances without direct cluster access. There
is also an `incident.sh` preset catalog and a config-driven `report.sh`
generator for multi-section event summaries.

To create new presets, see the **author-preset** skill; for new report
definitions, see the **author-report** skill.

## When you reach for this

You're investigating something in production and need real numbers or log
lines. The fastest path is almost always:

1. **Is there a preset?** Run `incident.sh list` and check. Presets encode
   queries that already proved useful in past incidents — start there before
   authoring a query from scratch.
2. **Metric question → `promql.sh`. Log question → `logql.sh`.** Rates, counts,
   percentiles, queue depths, lag → Prometheus. Error text, stack traces,
   "what is this service actually logging" → Loki.
3. **Narrow once you see signal.** Start broad (a preset or a `sum by (...)`),
   then add label filters and tighten the time window to isolate the problem.

## Invoking the scripts

When this skill is installed as a plugin, the scripts live at the plugin root.
Always invoke them through `$CLAUDE_PLUGIN_ROOT` so the path resolves wherever
the plugin is installed:

```bash
"$CLAUDE_PLUGIN_ROOT"/promql.sh '<query>'
"$CLAUDE_PLUGIN_ROOT"/logql.sh '<selector>'
"$CLAUDE_PLUGIN_ROOT"/incident.sh list
"$CLAUDE_PLUGIN_ROOT"/report.sh --help
```

(When working inside the repo itself rather than the installed plugin, the same
scripts are just `./promql.sh`, etc.)

Every script prints raw JSON from Grafana on stdout and exits non-zero with a
clear message on failure. Pipe through `jq` to read results — see
[references/queries.md](references/queries.md) for parsing recipes.

## Prerequisites: configuration and auth

Config comes from environment variables, usually via a gitignored `.env` — found
beside the scripts or at `~/.config/grafana-tools/.env` (the durable spot for
plugin installs; see `.env.example`). Each Grafana instance is a **named
environment** exposing a base URL and credentials. Two failure modes are **the
user's setup step, not something you can fix from a query**:

- **"No Grafana base URL configured"** — they need to set
  `GRAFANA_<ENV>_BASE_URL` (e.g. `GRAFANA_PROD_BASE_URL`), typically by copying
  `.env.example` to `.env` (repo checkout) or `~/.config/grafana-tools/.env`
  (plugin install) and filling it in.
- **"No Grafana credentials configured"** — they need auth for that environment:
  - **Token (preferred):** a Grafana API / service-account token in
    `GRAFANA_<ENV>_TOKEN` — bearer auth, non-interactive.
  - **Cookie (fallback):** the `Cookie:` request header from a logged-in browser
    session in `GRAFANA_<ENV>_COOKIE` (a single line like `_oauth2_proxy=…`).

Cookies expire periodically; a sudden `401`/auth failure usually means the
cookie needs refreshing. A token doesn't expire that way.

## Environments: default plus on-demand switch

The active environment is `GRAFANA_ENV` (if set for the command) → else the
`GRAFANA_DEFAULT_ENV` from `.env` → else `prod`. To target another instance for
a single command, set `GRAFANA_ENV`:

```bash
GRAFANA_ENV=staging "$CLAUDE_PLUGIN_ROOT"/promql.sh 'up{job="apiserver"}'
```

This picks that environment's base URL **and** its credentials together. Any
number of environments can be defined (prod, staging, eu, dev, …). When the user
says "on staging"/"in the EU cluster", set `GRAFANA_ENV` accordingly; otherwise
use the default.

## PromQL — metrics (`promql.sh`)

Instant query (current value):

```bash
"$CLAUDE_PLUGIN_ROOT"/promql.sh 'sum(rate(http_requests_total[5m]))'
```

Range query (time series over a window) — `--start`/`--end` are **Unix epoch
seconds**, `--step` is a duration (default `30s`):

```bash
"$CLAUDE_PLUGIN_ROOT"/promql.sh \
  --start 1712775600 --end 1712779200 --step 60s \
  'sum(rate(kafka_consumergroup_lag[5m]))'
```

Get epoch seconds with `date +%s` (now) or `date -v-1H +%s` (one hour ago, on
macOS) / `date -d '1 hour ago' +%s` (GNU).

## LogQL — logs (`logql.sh`)

Defaults to the **last hour**, up to 100 streams. The argument is a Loki
selector, optionally with line filters:

```bash
"$CLAUDE_PLUGIN_ROOT"/logql.sh '{namespace="default", app="api-server"}'
```

Tighten the window and add filters:

```bash
"$CLAUDE_PLUGIN_ROOT"/logql.sh \
  --since 900 --limit 50 \
  '{app="api-server"} |= "timeout"'
```

`--since` is a relative lookback in **seconds**. For an absolute window use
`--start`/`--end` in **nanoseconds** (note: PromQL uses seconds, Loki uses
nanoseconds — easy to mix up). `|=` is substring match, `|~` is regex.

## Incident presets (`incident.sh`)

Canned queries for recurring investigations, grouped one file per concern.
Presets load from the first of: `presets/local/*.sh` (a team's private,
gitignored set) → `~/.config/grafana-tools/presets/*.sh` (plugin installs) →
the committed generic `presets/example/*.sh`. List them, then run one:

```bash
"$CLAUDE_PLUGIN_ROOT"/incident.sh list
"$CLAUDE_PLUGIN_ROOT"/incident.sh run http/error-rate
```

Presets accept the same options as the underlying `promql.sh`/`logql.sh`
(e.g. `--since`, `--start`/`--end`/`--step`, `--limit`):

```bash
"$CLAUDE_PLUGIN_ROOT"/incident.sh run kafka/consumer-lag \
  --start 1775846700 --end 1775850300 --step 60s
```

The example groups (`kafka/*`, `http/*`, `queue/*`) are generic templates. A
team's real presets live in `presets/local/` and can be organized into whatever
groups fit (each `*.sh` file is a group). **Always run `incident.sh list` for
the authoritative set** — do not assume preset names. To add or edit presets,
use the **author-preset** skill.

## Report (`report.sh`)

Generates a multi-section report over a date range. The sections, metrics, and
labels come from a JSON **report definition** (a `title` plus an ordered list of
`scalar` / `range_max` / `topn` sections), so the tool carries no site-specific
queries. Definitions load from the first of: `reports/local/<name>.json` →
`~/.config/grafana-tools/reports/<name>.json` (plugin installs) → the committed
`reports/example/<name>.json`.

```bash
"$CLAUDE_PLUGIN_ROOT"/report.sh --start-date 2026-04-23 --days 3 --prefix launch
```

Writes `<prefix>.md`, `<prefix>.json`, and a CSV per section flagged `csv` to
`./out`. Use `--config <name>` to pick a definition (default `overview`) and
`report.sh --help` for all options. To create a new report definition, use the
**author-report** skill.

## Reference

- [references/queries.md](references/queries.md) — datasource details, the
  environment/auth variables, the preset and report-definition formats,
  PromQL/LogQL authoring tips, and `jq` recipes for reading the JSON output.
