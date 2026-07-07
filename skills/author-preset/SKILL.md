---
name: author-preset
description: >-
  Create, edit, and organize incident presets (the canned queries `incident.sh`
  runs). Use this when the user wants to add or change a preset,
  group/reorganize presets, or figure out the right Prometheus metric names,
  labels, or label values to put in one — e.g. "add a preset for X", "make an
  incident preset that checks Y", "what's the metric for Z", "why is my preset
  returning nothing". Complements the query skill, which runs the presets this
  one writes, and the author-report skill for reports.
---

# Authoring Incident Presets

Helps you write and organize incident presets in `presets/local/*.sh`,
discovering the right metric and label names against a live Grafana as you go.

The **query** skill and its [reference](../query/references/queries.md#preset-files-presets)
document the exact preset format and the environment/auth setup. Run the query
scripts through `$CLAUDE_PLUGIN_ROOT` (e.g. `"$CLAUDE_PLUGIN_ROOT"/promql.sh`).

## Golden rules

1. **Write to the private presets directory, never `presets/example/`.**
   In a repo checkout that's `presets/local/` (gitignored); when working from an
   installed plugin (no checkout), use `~/.config/grafana-tools/presets/` — it
   survives plugin updates. `example/` is the committed generic set; real metric
   names must not land there.
2. **Verify against real data before calling it done.** A preset that returns an
   empty result is usually a wrong metric or label name — discover, don't guess.
3. **Group by concern.** One `*.sh` file per group (e.g. `kafka.sh`,
   `checkout.sh`); `incident.sh` loads every file in the directory.

## Discovering metric & label names

Drive discovery through `promql.sh` and read the JSON with `jq` — no direct
Grafana access needed.

```bash
# Metric names matching a substring
"$CLAUDE_PLUGIN_ROOT"/promql.sh 'count by (__name__) ({__name__=~".*checkout.*"})' \
  | jq -r '.data.result[].metric.__name__' | sort -u

# Labels a metric carries (inspect one sample series)
"$CLAUDE_PLUGIN_ROOT"/promql.sh 'checkout_requests_total' \
  | jq -r '.data.result[0].metric | keys[]'

# Values of a label
"$CLAUDE_PLUGIN_ROOT"/promql.sh 'count by (status) (checkout_requests_total)' \
  | jq -r '.data.result[].metric.status' | sort -u
```

For logs, sample a broad selector to learn `app`/`namespace` labels, then narrow:

```bash
"$CLAUDE_PLUGIN_ROOT"/logql.sh --since 900 --limit 10 '{namespace="default"}' \
  | jq -r '.data.result[].stream.app' | sort -u
```

Keep windows/limits small while exploring; widen once the selector is right.

## Writing a preset

1. Pick or create the group file: `presets/local/<group>.sh` in a repo
   checkout, or `~/.config/grafana-tools/presets/<group>.sh` for a plugin
   install. (Note: `presets/local/` takes precedence — if it has any files, the
   config-dir presets are not loaded, so keep the team's set in one place.)
2. Add an entry — `define_preset <name> <promql|logql> <query> [description]`:

   ```bash
   define_preset "checkout/error-rate" promql \
     '100 * sum(rate(checkout_requests_total{status=~"5.."}[5m])) / clamp_min(sum(rate(checkout_requests_total[5m])), 1)' \
     "Checkout 5xx error rate (%)"
   ```

   Name is `group/name`; second field is `promql` or `logql`; the query is
   passed verbatim, so options given to `incident.sh run` flow through.
3. Dry-run it:

   ```bash
   "$CLAUDE_PLUGIN_ROOT"/incident.sh list | grep checkout
   "$CLAUDE_PLUGIN_ROOT"/incident.sh run checkout/error-rate
   ```

   A non-empty `data.result` (or a sensible zero) means the metric/labels
   resolve.

## Handing off

Private preset files never go in this repo. If `~/.config/grafana-tools` is a
git repo (the recommended team pattern), commit the new preset there and open a
PR so teammates get it with `git pull`; otherwise distribute the file directly.
Anything generic enough to help everyone could instead be contributed to
`presets/example/`.
