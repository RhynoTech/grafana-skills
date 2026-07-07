---
name: author-report
description: >-
  Create and edit report definitions — the JSON that drives the `report.sh`
  multi-section reports. Use this when the user wants to build a new
  report, add/change a section (a metrics table, a resource-peak table, or a
  top-N breakdown), or figure out the right Prometheus metric names and labels to
  put in one — e.g. "make a report for X", "add a section showing Y", "build a
  weekly overview report". Complements the query skill, which runs the reports
  this one writes, and the author-preset skill for presets.
---

# Authoring Report Definitions

Helps you write report definitions in `reports/local/*.json`, discovering the
right metric and label names against a live Grafana as you go.

The **query** skill and its [reference](../query/references/queries.md#report-definitions-reports)
document the definition schema and the environment/auth setup. Run the query
scripts through `$CLAUDE_PLUGIN_ROOT`.

## Golden rules

1. **Write to the private reports directory, never `reports/example/`.**
   In a repo checkout that's `reports/local/` (gitignored); when working from an
   installed plugin (no checkout), use `~/.config/grafana-tools/reports/` — it
   survives plugin updates. `example/` is the committed generic set; real metric
   names must not land there.
2. **Verify against real data before calling it done.** Dry-run and check the
   numbers are populated — an all-zero section usually means a wrong metric name.

## Discovering metric & label names

Drive discovery through `promql.sh` and read the JSON with `jq`:

```bash
# Metric names matching a substring
"$CLAUDE_PLUGIN_ROOT"/promql.sh 'count by (__name__) ({__name__=~".*checkout.*"})' \
  | jq -r '.data.result[].metric.__name__' | sort -u

# Labels a metric carries, and a label's values
"$CLAUDE_PLUGIN_ROOT"/promql.sh 'checkout_requests_total' \
  | jq -r '.data.result[0].metric | keys[]'
"$CLAUDE_PLUGIN_ROOT"/promql.sh 'count by (service) (checkout_requests_total)' \
  | jq -r '.data.result[].metric.service' | sort -u
```

## The definition format

A definition is JSON: a `title` and an ordered list of `sections`. The engine
substitutes `__W__` (window length in hours) and `__TS__` (epoch `@`-modifier)
into each query; PromQL braces need no escaping. Three section kinds:

- **`scalar`** — `{metrics: [{label, query, fmt?}]}`; each metric summed and
  shown per day + a window total. `fmt` ∈ `int` (default) | `float` | `pct` |
  `seconds`. Express a rate/ratio (e.g. error rate %) as one query with
  `"fmt": "pct"` — don't derive it from other rows.
- **`range_max`** — `{metrics: [{label, query, fmt?}]}`; each query is a range
  query and the section shows the per-day peak (CPU, memory, latency). These use
  their own `[5m]` windows and ignore `__W__`/`__TS__`.
- **`topn`** — a single `{query}` (a `by (...)` aggregation) showing the top
  rows. Options: `top` (default 10), `item_label`, `fmt`, `csv: true` to also
  write `<prefix>-<section-slug>.csv`.

See `reports/example/overview.json` for a complete example.

## Writing a definition

1. Copy the example: `cp reports/example/overview.json reports/local/<name>.json`
   (repo checkout) or to `~/.config/grafana-tools/reports/<name>.json` (plugin
   install).
2. Set the `title` and edit `sections` — add/replace/reorder to fit. Put your
   discovered metric names into each query, keeping the `__W__`/`__TS__` tokens.
3. Dry-run over a short window:

   ```bash
   "$CLAUDE_PLUGIN_ROOT"/report.sh --config <name> --start-date 2026-01-01 --days 1 \
     --out-dir /tmp/report-check
   ```

   Open the generated `.md`/`.json` and sanity-check the numbers.

## Handing off

Private report definitions never go in this repo. If `~/.config/grafana-tools`
is a git repo (the recommended team pattern), commit the new definition there
and open a PR so teammates get it with `git pull`; otherwise distribute the file
directly.
