# Grafana Query Helpers

Thin wrappers around Grafana's datasource proxy APIs for Prometheus and Loki,
plus canned incident presets and a config-driven cross-system report.

These helpers authenticate with a per-environment Grafana **token or session
cookie** (from a gitignored `.env`) so they can query Grafana without direct
cluster access. Any number of Grafana instances / environments are supported.

You can use the scripts directly from the shell, or install the repo as a
**Claude Code plugin** so Claude knows when and how to drive them during incident
investigations.

## Use with Claude Code (plugin)

This repo doubles as a Claude Code plugin marketplace (`grafana-skills`) whose
`grafana-tools` plugin bundles three skills — `query` (run queries/presets/
reports), `author-preset` (create presets), and `author-report` (create report
definitions). To install:

```
/plugin marketplace add RhynoTech/grafana-skills
/plugin install grafana-tools@grafana-skills
```

(Working from a local checkout instead? `/plugin marketplace add ./grafana-skills`.)

Once installed, Claude reaches for these skills automatically — `query` when you
ask it to investigate metrics or logs (Kafka lag, error rates, queue backlogs,
alert triage), and `author-preset` / `author-report` when you ask it to create a
new preset or report. The skills live in [`skills/`](skills/) and invoke the same
scripts described below.

## Setup

1. Clone this repo (or install it as a Claude Code plugin, above).
2. **Configure your Grafana instance(s).** Copy the example env file and fill it
   in:

   ```bash
   cp .env.example .env                                  # repo checkout
   # — or, for a plugin install (survives plugin updates):
   mkdir -p ~/.config/grafana-tools && cp .env.example ~/.config/grafana-tools/.env
   ```

   `.env` is gitignored, so no hostnames or credentials land in the repo. Each
   Grafana is a **named environment** — set at least `GRAFANA_<ENV>_BASE_URL`
   and one credential (below). Real shell env vars override `.env`.
3. **Authenticate** per environment with either:
   - **Token (preferred):** a Grafana API / service-account token in
     `GRAFANA_<ENV>_TOKEN` — bearer auth, non-interactive.
   - **Cookie (fallback):** the whole `Cookie:` request header from a logged-in
     browser session in `GRAFANA_<ENV>_COOKIE` (a single line like
     `_oauth2_proxy=…; …`).
4. Optional: add the repo directory to your `PATH` so you can run `promql.sh` /
   `logql.sh` / `incident.sh` without the full path.

## Team setup (private presets, reports, and config)

Site-specific queries never live in this repo — they belong in one of two
places, checked in this order:

| What | Repo checkout (gitignored) | Plugin install / durable |
| --- | --- | --- |
| Environment + auth | `.env` | `~/.config/grafana-tools/.env` |
| Presets | `presets/local/*.sh` | `~/.config/grafana-tools/presets/*.sh` |
| Report definitions | `reports/local/*.json` | `~/.config/grafana-tools/reports/*.json` |

**Recommended team pattern:** make `~/.config/grafana-tools` itself a private
git repo containing `presets/`, `reports/`, a team `.env.example` (endpoints
committed, tokens not), and a `.gitignore` for `.env`:

```bash
# each teammate, once
git clone git@github.com:<org>/grafana-team-config.git ~/.config/grafana-tools
cp ~/.config/grafana-tools/.env.example ~/.config/grafana-tools/.env  # add personal token

# new presets/reports land via PRs; pick them up with
git -C ~/.config/grafana-tools pull
```

New presets get code review, updates are one `git pull`, plugin updates never
touch the directory, and everything falls back to the committed `example/`
files when nothing private is present.

## Environments

The active environment is `GRAFANA_ENV` (per command) → else `GRAFANA_DEFAULT_ENV`
(from `.env`) → else `prod`. Queries hit the default; switch per command with
`GRAFANA_ENV`:

```bash
./promql.sh 'up{job="apiserver"}'                    # default env
GRAFANA_ENV=staging ./promql.sh 'up{job="apiserver"}' # staging instance
```

Each environment carries its own base URL, credentials, and (optionally)
datasource UIDs. Define as many as you like in `.env` — `prod`, `staging`, `eu`,
`dev`, … — via `GRAFANA_<NAME>_*` variables. A single-instance setup can use the
unprefixed `GRAFANA_BASE_URL` / `GRAFANA_TOKEN` / `GRAFANA_COOKIE` instead.

## PromQL

Instant query:

```bash
./promql.sh 'up{job="apiserver"}'
```

Range query (`--start`/`--end` are Unix epoch **seconds**):

```bash
./promql.sh \
  --start 1712775600 \
  --end 1712776500 \
  --step 30s \
  'sum(rate(kafka_consumergroup_lag[5m]))'
```

## LogQL

Last hour by default:

```bash
./logql.sh '{namespace="default", app="api-server"}'
```

Explicit window (`--start`/`--end` are **nanoseconds**; `--since` is seconds):

```bash
./logql.sh \
  --since 900 \
  --limit 50 \
  '{app="api-server"} |= "timeout"'
```

## Incident presets

Presets are grouped one file per concern. They load from the first of:
`presets/local/*.sh` (your team's private, gitignored set) →
`~/.config/grafana-tools/presets/*.sh` (for plugin installs) → the committed
generic `presets/example/*.sh`. Point `GRAFANA_QUERY_PRESETS_DIR` at any
directory to override.

```bash
./incident.sh list                       # list available presets
./incident.sh run http/error-rate        # run one
./incident.sh run kafka/consumer-lag --start 1775846700 --end 1775850300 --step 60s
```

Options after the preset name pass through to `promql.sh` / `logql.sh`. To add
your own presets, copy the pattern from `presets/example/` into a
`presets/local/<group>.sh` (or use the `author-preset` skill).

## Report

`report` generates a multi-section report over a date range. The sections,
metrics, and labels come from a JSON **report definition** (a `title` plus an
ordered list of `scalar` / `range_max` / `topn` sections), so the engine carries
no site-specific queries. Definitions load from the first of:
`reports/local/<name>.json` → `~/.config/grafana-tools/reports/<name>.json`
(for plugin installs) → `reports/example/<name>.json`.

```bash
./report.sh --start-date 2026-04-23 --days 3 --prefix launch
```

Outputs go to `./out` by default:

- `<prefix>.md` (human-readable report)
- `<prefix>.json` (all computed section data)
- `<prefix>-<section>.csv` (one per `topn` section flagged `"csv": true`)

Use `--config <name>` to select a definition (default `overview`) and
`./report.sh --help` for all options. To create a new definition, copy
`reports/example/overview.json` to `reports/local/` and edit (or use the
`author-report` skill).

## Configuration reference

All config is environment variables, optionally from `.env` (see
[`.env.example`](.env.example)). `<ENV>` is the active environment name,
uppercased with non-alphanumerics turned into `_`.

- `GRAFANA_ENV` / `GRAFANA_DEFAULT_ENV`: active / default environment (default `prod`).
- `GRAFANA_<ENV>_BASE_URL`: Grafana base URL for that environment (**required**).
- `GRAFANA_<ENV>_TOKEN`: API/service-account token (bearer auth; preferred).
- `GRAFANA_<ENV>_COOKIE`: session cookie header (fallback auth).
- `GRAFANA_<ENV>_PROMETHEUS_UID` / `GRAFANA_<ENV>_LOKI_UID`: datasource UIDs (default `prometheus` / `loki`).
- `GRAFANA_BASE_URL` / `GRAFANA_TOKEN` / `GRAFANA_COOKIE` / `GRAFANA_PROMETHEUS_UID` / `GRAFANA_LOKI_UID`: unprefixed single-instance fallbacks.
- `GRAFANA_QUERY_ENV_FILE`: path to the `.env` to load (`/dev/null` disables). Default lookup: `.env` beside the scripts → `~/.config/grafana-tools/.env`.
- `GRAFANA_QUERY_PRESETS_DIR` / `GRAFANA_QUERY_REPORTS_DIR`: override the presets / report-definitions directory.
- `XDG_CONFIG_HOME`: relocates the `~/.config/grafana-tools` directory.

## Tests

The test suite stubs `curl` and asserts the shaped requests sent to Grafana. Run
with:

```bash
node --test grafana-query.test.mjs
```

No `npm install` / `pnpm install` required — tests use only `node:*` built-ins.

## License

[MIT](LICENSE)
