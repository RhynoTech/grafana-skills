# Windows, Limits, and Incomplete Answers

Every limit in this stack produces a **plausible wrong answer** rather than an
error. A window that is too big returns an HTTP 502 that reads like an outage. A
result that is too big comes back silently truncated. A range that reaches past
retention comes back short with no gap marker. None of these look like failures,
and all of them have been quoted as findings.

The rule that follows from it: **never widen a window until it breaks.** Start
narrow, measure what the query cost, and sweep the range in chunks.

## The four ceilings

| Ceiling | How it shows up | What it actually means |
| --- | --- | --- |
| Gateway timeout | HTTP `502` after ~30s | The query was too expensive. Not an outage, not an absence. |
| Loki line limit | Exactly `--limit` rows returned | Truncated to the **newest** N lines. |
| Prometheus point limit | HTTP `400`, body names 11,000 points | `(end-start)/step` exceeded the cap. |
| Retention | A short or empty result, no error | The data is gone. Silent in both stores. |

### The gateway timeout is about volume, not hours

There is no fixed "safe" window length — the ceiling is **lines scanned**, so it
moves with the selector. Measured on one production cluster, same 6h window:

- `{app="one-service"} |~ "..."` → 81,692 lines scanned, returns in 1s.
- `{namespace="default"} |~ "..."` → over 10M lines scanned per hour, and 6h
  `502`s after exactly 30 seconds.

So "6h works" is a property of the selector, never of the time range. Read
`data.stats.summary.totalLinesProcessed` from any successful query to learn what
your selector actually costs, then size the chunk from that.

### Truncation is silent, and it lies about *when*

Loki returns the **newest** lines first. A query that comes back with exactly
`--limit` rows is therefore truncated, and its oldest timestamp is wherever the
tail of the last N lines happened to fall — **not** the start of the episode.

Both the count and the onset from a capped window are fabrications. Compare
`len(rows)` against the limit on every pull. If they are equal, split the window
until every chunk returns under the limit.

### Retention is a cliff with no railing

A range query reaching past retention does not error and does not mark the gap.
It simply returns fewer points than you asked for. On one production cluster a
30-day range at a 1h step returned 362 points — about 15 days — with a
`"status":"success"`.

Metrics retention is often **shorter** than log retention, which is the opposite
of most people's intuition. Probe it rather than assuming: run the same cheap
query at 5d, 10d, 20d, 40d and find where it goes empty. Anything older than the
horizon has to come from a file someone saved while it was still in the window.

## The results cache will confirm your own mistake

Re-running a query over an **identical** window returns the stored answer and
reports `totalLinesProcessed: 0`. That is indistinguishable at a glance from a
query that genuinely scanned nothing — which is exactly what you look at when
you re-check a zero.

Measured, same query twice over the same window:

| | lines processed | `cache.result.entriesFound` |
| --- | --- | --- |
| First run | 11,531 | 0 |
| Second run | **0** | 5 |

`data.stats.cache.result` is the field that tells them apart — `entriesFound` or
`queryLengthServed` above zero means the answer came from cache. To force a real
scan, shift the window by a few seconds so the cache key changes.

This also breaks cost estimates in the other direction: a wide window whose
sub-windows are already cached will **succeed cheaply**, then `502` when run over
a cold range of the same width. A window size proven on warm cache proves nothing
about a cold one.

## Sweeping instead of widening

`sweep.sh` encodes all of the above: it tiles the range into non-overlapping
half-open chunks, halves any chunk that `502`s, splits any chunk that comes back
capped, sizes PromQL chunks against the point limit, flags cache-served chunks,
and refuses to present an incomplete sweep as a total.

```bash
# Every matching line over 7 days, no truncation, oldest first
"$CLAUDE_PLUGIN_ROOT"/sweep.sh --since 7d '{app="api"} |= "ECONNRESET"' > lines.jsonl

# Per-day counts over 30 days
"$CLAUDE_PLUGIN_ROOT"/sweep.sh --since 30d --chunk 1d --mode count \
  '{app="api"} | json | level="error"'

# A 30-day range query that would otherwise trip the point limit
"$CLAUDE_PLUGIN_ROOT"/sweep.sh --type promql --since 30d --step 1h \
  'sum(rate(http_requests_total[5m]))'
```

Chunk sizing, as a starting point — then let the tool adapt:

| Selector breadth | Loki chunk | Notes |
| --- | --- | --- |
| One app, tight line filter | `6h` – `1d` | Usually cheap enough to go wide. |
| One app, no filter | `1h` | Volume-dependent; watch the scan count. |
| Namespace-wide | `15m` – `1h` | Tens of millions of lines per hour. |
| Unknown | `1h` | Run one chunk, read the scan count, then resize. |

**Exit code 2 means the sweep is incomplete** — some chunk failed, or stayed
capped at `--min-chunk`. The total it printed is a floor. Do not quote it.

`--summary-json` writes the per-chunk ledger: what each window scanned, what was
split, what stayed degraded. Keep it next to any number you plan to publish; it
is the difference between "zero occurrences" and "zero matches across 57.1M lines
scanned, complete coverage, no failed chunks".

## Counting without fabricating

Do not count with overlapping windows. `sum(count_over_time({...}[10m]))` run as
a range query whose step is smaller than 10m counts every line once per
overlapping window. That inflates the total **and** stretches a one-second burst
into one that looks minutes long — and a wrong duration quietly invalidates whole
classes of explanation.

For a total, use one window that spans the whole period and read the last value,
or use `sweep.sh --mode count`, whose chunks are half-open and tile exactly. To
establish *shape*, fetch raw lines and bucket the timestamps yourself.

## Before writing down a zero

A zero is a measurement only if you can say what it scanned. Ask which of these
produced it:

- a window that `502`d and was silently skipped
- a result truncated at `--limit`
- a range past the retention horizon
- a cache-served chunk reporting zero scanned lines
- an expired session answering every query with a login redirect
- a selector whose label or value does not exist

If none can be ruled out, the honest sentence is "no evidence found, and here is
what that query could not have seen."
