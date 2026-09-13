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
  Also use it whenever a question spans a long range (days or weeks of logs or
  metrics, a backfill, a trend, "how often has this happened this month"), since
  both datasources silently truncate or reject wide windows and the range has to
  be swept in chunks. Prefer these helpers over hand-rolled curl against Grafana.
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

1. **Is it already written down?** Run `incident.sh list` — presets encode
   queries that already proved useful in past incidents. Then read `LEARNED.md`
   in your config directory (`~/.config/grafana-tools/LEARNED.md`) if it exists:
   it holds the label names, metric names, and traps this system has already cost
   someone an afternoon. Both beat authoring from scratch.
2. **Metric question → `promql.sh`. Log question → `logql.sh`.** Rates, counts,
   percentiles, queue depths, lag → Prometheus. Error text, stack traces,
   "what is this service actually logging" → Loki.
3. **Narrow once you see signal.** Start broad (a preset or a `sum by (...)`),
   then add label filters and tighten the time window to isolate the problem.
4. **Sweep, don't widen.** Anything past a few hours of logs goes through
   `sweep.sh`. Widening a window until it fails is how you get a `502` that reads
   as an outage, or a truncated result that reads as a complete one.
5. **Write down what surprised you.** See *Record what you learn* below — a trap
   you hit today is one the next run should not have to rediscover.

## Invoking the scripts

When this skill is installed as a plugin, the scripts live at the plugin root.
Always invoke them through `$CLAUDE_PLUGIN_ROOT` so the path resolves wherever
the plugin is installed:

```bash
"$CLAUDE_PLUGIN_ROOT"/promql.sh '<query>'
"$CLAUDE_PLUGIN_ROOT"/logql.sh '<selector>'
"$CLAUDE_PLUGIN_ROOT"/sweep.sh --since 7d '<selector>'
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

## Long ranges: sweep, never widen (`sweep.sh`)

Both datasources refuse large queries, and **not one of those refusals looks like
a refusal**:

- Loki answers an over-large window with an HTTP `502` from the gateway — which
  reads as an outage, not a cost ceiling.
- Loki answers an over-large *result* by truncating to `--limit` and returning
  the **newest** lines, so the oldest timestamp you see is not the start of
  anything.
- Prometheus refuses more than 11,000 points per series with an HTTP `400`.
- Both stores silently return less than you asked for once you reach past
  retention. No error, no gap marker.

So do not widen a window until it breaks. Sweep the range in chunks:

```bash
"$CLAUDE_PLUGIN_ROOT"/sweep.sh --since 7d '{app="api"} |= "ECONNRESET"'
"$CLAUDE_PLUGIN_ROOT"/sweep.sh --since 30d --chunk 1d --mode count '{app="api"} |= "error"'
"$CLAUDE_PLUGIN_ROOT"/sweep.sh --type promql --since 30d --step 1h 'sum(rate(http_requests_total[5m]))'
```

`sweep.sh` tiles the range into non-overlapping chunks, halves any chunk that
`502`s, splits any chunk that comes back capped, sizes PromQL chunks against the
point limit, and flags chunks served from Loki's results cache. **It exits 2 when
the sweep is incomplete** — the total it printed is then a floor, not a count.

The ceiling is **lines scanned, not hours**: a tight selector may sweep a day at
a time while a namespace-wide one struggles past 15 minutes. Read
`data.stats.summary.totalLinesProcessed` from a first chunk to size the rest.

[references/windows-and-limits.md](references/windows-and-limits.md) has the
measurements, the chunk-size table, and the cache trap in full. Read it before
quoting any count, duration, or zero.

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

## Record what you learn

This skill is meant to get better every time it is used. Two things are worth
writing down the moment you find them, because the next run cannot rediscover
them for free.

### 1. A trap, a limit, or a correction

Whenever a query **lied** — an empty result from a wrong label, a window that
`502`d, a count inflated by overlapping windows, a metric whose exported name was
not what the naming convention implied, a cache-served zero — write it down
before moving on. The test is simple: *would the next person have believed the
wrong answer?* If yes, it is worth a note.

Route it by what kind of fact it is:

- **A fact about the tools or the query engines** — a limit, a response shape, a
  flag, a way one of these stores misleads you. Generic: it would be true at any
  company. Add it to
  [references/windows-and-limits.md](references/windows-and-limits.md) or the
  relevant section of this skill, and note the measurement that proves it.
- **A fact about your systems** — a label value, an exported metric name, a
  service that is really three services, a threshold, a consumer group, a
  retention figure. Site-specific: it must **not** land in this repo. Write it to
  `LEARNED.md` in your private config directory
  (`~/.config/grafana-tools/LEARNED.md`), which the team shares and plugin
  updates never touch.

Keep each entry to a few lines: what you expected, what actually happened, the
measurement, and the rule to apply next time. Date it. A wrong entry is worse
than no entry, so record what you **measured**, not what you inferred — and when
a later run contradicts an entry, correct it rather than appending a second
version.

### 2. A query you have now run twice

A query you needed twice is a query you will need again, and re-deriving it costs
the same every time. Promote it to a **preset** (see the **author-preset** skill)
so it is one `incident.sh run` away, and to a **report section** (see the
**author-report** skill) if it belongs in a recurring health picture.

The bar is low on purpose. A preset that turns out to be wrong is cheap to fix; a
query rebuilt from scratch on every incident is not. Run `incident.sh list` at
the start of an investigation — the answer may already be written down.

## Reference

- [references/queries.md](references/queries.md) — datasource details, the
  environment/auth variables, the preset and report-definition formats,
  PromQL/LogQL authoring tips, and `jq` recipes for reading the JSON output.
- [references/windows-and-limits.md](references/windows-and-limits.md) — the four
  ceilings (gateway timeout, line limit, point limit, retention), how each one
  fakes a plausible answer, the results-cache trap, chunk sizing, and what has to
  be true before you write down a zero.
