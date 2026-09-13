#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

type="logql"
start=""
end=""
since=""
chunk=""
min_chunk="1m"
limit="1000"
step="1m"
mode=""
out=""
summary_json=""

usage() {
  cat <<'USAGE'
Usage: sweep.sh [options] '<query>'

Walk a long time range in chunks that the datasource will actually serve, and
merge the results. Use this instead of widening a window until it fails.

Both datasources refuse large windows, but neither refusal looks like one:
  - Loki answers an over-large window with an HTTP 502 from the gateway, which
    reads as an outage rather than a cost ceiling.
  - Loki answers an over-large *result* by silently truncating to --limit and
    returning the NEWEST lines, so the oldest timestamp you see is not the start
    of anything.
  - Prometheus refuses more than 11,000 points per series with an HTTP 400, and
    silently returns only what it still retains for anything older.

sweep.sh handles all three: it halves a chunk that 502s, splits a chunk that
comes back capped, and sizes PromQL chunks against the point limit.

Options:
  --type <promql|logql>   Datasource. Default: logql.
  --since <duration>      Relative lookback (e.g. 6h, 7d, 30d).
  --start <epoch seconds> Absolute range start (seconds, both datasources).
  --end <epoch seconds>   Absolute range end. Default: now.
  --chunk <duration>      Starting chunk size. Default: 1h (logql), 6h (promql).
  --min-chunk <duration>  Smallest chunk to try before giving up. Default: 1m.
  --limit <count>         Loki lines per chunk. Default: 1000.
  --step <duration>       PromQL step. Default: 1m.
  --mode <lines|count|agg|range>
                          logql: "lines" (default) emits every matching line as
                          JSONL; "count" emits per-chunk counts by pulling lines;
                          "agg" counts SERVER-SIDE with count_over_time, which
                          returns a number instead of lines — far cheaper, and
                          immune to the --limit truncation entirely. Prefer "agg"
                          whenever you only need totals.
                          promql: "range" (default) emits one merged range result.
  --out <path>            Write merged output here instead of stdout.
  --summary-json <path>   Write the per-chunk ledger as JSON (what was scanned,
                          what was split, what stayed degraded).
  --help                  Show this help text.

Every chunk is a half-open window [start, end), so chunks tile the range without
overlapping. That matters: overlapping windows double-count, and they stretch a
one-second burst into a burst that looks minutes long.

Examples:
  # Every matching line over 7 days, no truncation, oldest first
  sweep.sh --since 7d '{app="api"} |= "ECONNRESET"' > lines.jsonl

  # Per-day counts over 30 days
  sweep.sh --since 30d --chunk 1d --mode count '{app="api"} | json | level="error"'

  # A 30-day range query without tripping the 11,000-point limit
  sweep.sh --type promql --since 30d --step 1h 'sum(rate(http_requests_total[5m]))'
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) type="$2"; shift 2 ;;
    --since) since="$2"; shift 2 ;;
    --start) start="$2"; shift 2 ;;
    --end) end="$2"; shift 2 ;;
    --chunk) chunk="$2"; shift 2 ;;
    --min-chunk) min_chunk="$2"; shift 2 ;;
    --limit) limit="$2"; shift 2 ;;
    --step) step="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --summary-json) summary_json="$2"; shift 2 ;;
    --help) usage; exit 0 ;;
    --*) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    *) break ;;
  esac
done

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

query="$*"

if [[ "$type" != "promql" && "$type" != "logql" ]]; then
  printf 'Unknown --type "%s" (expected promql or logql).\n' "$type" >&2
  exit 1
fi

if [[ -z "$since" && -z "$start" ]]; then
  printf 'Give a range: --since <duration>, or --start (and optionally --end).\n' >&2
  exit 1
fi

[[ -z "$chunk" ]] && { [[ "$type" == "promql" ]] && chunk="6h" || chunk="1h"; }
[[ -z "$mode" ]] && { [[ "$type" == "promql" ]] && mode="range" || mode="lines"; }

python3 - "$SCRIPT_DIR" "$type" "$query" "$start" "$end" "$since" "$chunk" \
  "$min_chunk" "$limit" "$step" "$mode" "$out" "$summary_json" <<'PY'
import json
import os
import subprocess
import sys
import time

(
    script_dir, qtype, query, start_s, end_s, since_s, chunk_s,
    min_chunk_s, limit_s, step_s, mode, out_path, summary_path,
) = sys.argv[1:14]

# Prometheus refuses more than this many points per series, with an HTTP 400
# whose body names the limit. Staying under it is cheaper than discovering it.
PROM_MAX_POINTS = 11000


def parse_duration(text):
    units = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}
    text = text.strip()
    if text and text[-1] in units:
        return int(float(text[:-1]) * units[text[-1]])
    return int(float(text))


limit = int(limit_s)
chunk = parse_duration(chunk_s)
min_chunk = parse_duration(min_chunk_s)
step = parse_duration(step_s)

end = int(end_s) if end_s else int(time.time())
start = int(start_s) if start_s else end - parse_duration(since_s)
if start >= end:
    sys.exit("Range start is not before its end.")

ledger = []


def note(msg):
    print(msg, file=sys.stderr)


def run_script(name, args):
    proc = subprocess.run(
        [os.path.join(script_dir, name)] + args,
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout, proc.stderr


def too_expensive(stderr):
    # common.sh turns a gateway 502/503/504 into this message; the datasource
    # never says "your window is too big" in as many words.
    return "too expensive to finish" in stderr or "HTTP 50" in stderr


def auth_failed(stderr):
    return "auth failed" in stderr


def fetch_logql(lo, hi):
    rc, out, err = run_script(
        "logql.sh",
        ["--start", f"{lo}000000000", "--end", f"{hi}000000000",
         "--limit", str(limit), query],
    )
    return rc, out, err


def fetch_promql(lo, hi, this_step):
    rc, out, err = run_script(
        "promql.sh",
        ["--start", str(lo), "--end", str(hi), "--step", f"{this_step}s", query],
    )
    return rc, out, err


def stamp(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def entries_of(payload):
    rows = []
    for stream in payload.get("data", {}).get("result", []):
        labels = stream.get("stream", {})
        for ts, line in stream.get("values", []):
            rows.append((int(ts), line, labels))
    return rows


def scanned(payload):
    stats = payload.get("data", {}).get("stats", {})
    summary = stats.get("summary", {})
    result_cache = stats.get("cache", {}).get("result", {})
    # Loki serves a repeated window from its results cache and then reports
    # totalLinesProcessed=0 — indistinguishable at a glance from a query that
    # scanned nothing. cache.result is the field that tells them apart.
    cached = (
        result_cache.get("entriesFound", 0) > 0
        or result_cache.get("queryLengthServed", 0) > 0
    )
    return summary.get("totalLinesProcessed", 0), cached


def sweep_logql():
    rows = []
    counts = []
    # A work queue rather than recursion, so a chunk that has to be split many
    # times cannot blow the stack on a multi-week sweep.
    queue = []
    lo = start
    while lo < end:
        queue.append((lo, min(lo + chunk, end)))
        lo += chunk
    queue.reverse()

    while queue:
        lo, hi = queue.pop()
        rc, out, err = fetch_logql(lo, hi)

        if rc != 0:
            if auth_failed(err):
                sys.exit(err.strip() or "Grafana auth failed.")
            span = hi - lo
            if too_expensive(err) and span > min_chunk:
                mid = lo + span // 2
                note(f"  {stamp(lo)} .. {stamp(hi)}  502 -> splitting ({span}s)")
                queue.append((mid, hi))
                queue.append((lo, mid))
                continue
            note(f"  {stamp(lo)} .. {stamp(hi)}  FAILED: {err.strip().splitlines()[-1] if err.strip() else rc}")
            ledger.append({"start": lo, "end": hi, "status": "failed", "error": err.strip()})
            continue

        payload = json.loads(out, strict=False)
        chunk_rows = entries_of(payload)
        lines_scanned, cached = scanned(payload)
        span = hi - lo

        # Exactly --limit rows means Loki truncated, and it returns the NEWEST
        # lines — so this window's oldest timestamp is meaningless and its count
        # is a floor. Split until every window comes back under the limit.
        if len(chunk_rows) >= limit and span > min_chunk:
            mid = lo + span // 2
            note(f"  {stamp(lo)} .. {stamp(hi)}  capped at {limit} -> splitting ({span}s)")
            queue.append((mid, hi))
            queue.append((lo, mid))
            continue

        degraded = len(chunk_rows) >= limit
        if degraded:
            note(f"  {stamp(lo)} .. {stamp(hi)}  STILL CAPPED at --min-chunk: count is a floor")

        rows.extend(chunk_rows)
        counts.append((lo, hi, len(chunk_rows)))
        ledger.append({
            "start": lo, "end": hi, "status": "degraded" if degraded else "ok",
            "returned": len(chunk_rows), "lines_scanned": lines_scanned,
            "cached": cached,
        })
        mark = "  [cached]" if cached else ""
        note(f"  {stamp(lo)} .. {stamp(hi)}  {len(chunk_rows):>6} lines  ({lines_scanned:,} scanned){mark}")

    return rows, counts


def sweep_logql_agg():
    """Count matches per chunk with count_over_time, evaluated once per chunk.

    Counting server-side avoids pulling lines at all, so --limit truncation
    cannot apply. The evaluation is a single instant per chunk over a range
    exactly equal to the chunk, so windows never overlap and nothing is
    double-counted.
    """
    counts = []
    queue = []
    lo = start
    while lo < end:
        queue.append((lo, min(lo + chunk, end)))
        lo += chunk
    queue.reverse()

    while queue:
        lo, hi = queue.pop()
        span = hi - lo
        rc, out, err = run_script(
            "logql.sh",
            ["--start", f"{hi - 1}000000000", "--end", f"{hi}000000000",
             "--limit", "10", f"sum(count_over_time({query}[{span}s]))"],
        )
        if rc != 0:
            if auth_failed(err):
                sys.exit(err.strip() or "Grafana auth failed.")
            if too_expensive(err) and span > min_chunk:
                mid = lo + span // 2
                note(f"  {stamp(lo)} .. {stamp(hi)}  502 -> splitting ({span}s)")
                queue.append((mid, hi))
                queue.append((lo, mid))
                continue
            note(f"  {stamp(lo)} .. {stamp(hi)}  FAILED")
            ledger.append({"start": lo, "end": hi, "status": "failed", "error": err.strip()})
            continue

        payload = json.loads(out, strict=False)
        total = 0
        for frame in payload.get("data", {}).get("result", []):
            vals = frame.get("values") or ([frame["value"]] if "value" in frame else [])
            if vals:
                total += int(float(vals[-1][1]))
        _, cached = scanned(payload)
        counts.append((lo, hi, total))
        ledger.append({"start": lo, "end": hi, "status": "ok",
                       "returned": total, "cached": cached})
        note(f"  {stamp(lo)} .. {stamp(hi)}  {total:>6} matches")

    return counts


def sweep_promql():
    series = {}
    queue = []
    lo = start
    while lo < end:
        queue.append((lo, min(lo + chunk, end)))
        lo += chunk
    queue.reverse()

    while queue:
        lo, hi = queue.pop()
        span = hi - lo
        this_step = step
        # Size against the point limit before asking, rather than learning about
        # it from a 400.
        if span // this_step > PROM_MAX_POINTS:
            mid = lo + span // 2
            if span > min_chunk:
                queue.append((mid, hi))
                queue.append((lo, mid))
                continue

        rc, out, err = fetch_promql(lo, hi, this_step)
        if rc != 0:
            if auth_failed(err):
                sys.exit(err.strip() or "Grafana auth failed.")
            if (too_expensive(err) or "11,000 points" in err) and span > min_chunk:
                mid = lo + span // 2
                note(f"  {stamp(lo)} .. {stamp(hi)}  rejected -> splitting ({span}s)")
                queue.append((mid, hi))
                queue.append((lo, mid))
                continue
            note(f"  {stamp(lo)} .. {stamp(hi)}  FAILED")
            ledger.append({"start": lo, "end": hi, "status": "failed", "error": err.strip()})
            continue

        payload = json.loads(out, strict=False)
        points = 0
        for frame in payload.get("data", {}).get("result", []):
            key = json.dumps(frame.get("metric", {}), sort_keys=True)
            bucket = series.setdefault(key, {})
            for ts, val in frame.get("values", []):
                bucket[int(ts)] = val
                points += 1
        ledger.append({"start": lo, "end": hi, "status": "ok", "points": points})
        note(f"  {stamp(lo)} .. {stamp(hi)}  {points:>6} points")

    return series


note(f"sweep {qtype} {stamp(start)} .. {stamp(end)}  chunk={chunk_s} mode={mode}")

if qtype == "logql" and mode == "agg":
    counts = sweep_logql_agg()
    body = "\n".join(
        json.dumps({"start": stamp(lo), "end": stamp(hi), "count": n})
        for lo, hi, n in counts
    ) + "\n"
    total = sum(n for _, _, n in counts)
elif qtype == "logql":
    rows, counts = sweep_logql()
    rows.sort(key=lambda r: r[0])
    if mode == "count":
        lines = [
            json.dumps({"start": stamp(lo), "end": stamp(hi), "count": n})
            for lo, hi, n in counts
        ]
        body = "\n".join(lines) + "\n"
        total = sum(n for _, _, n in counts)
    else:
        body = "".join(
            json.dumps({"ts": ts, "time": stamp(ts / 1e9), "line": line, "labels": labels}) + "\n"
            for ts, line, labels in rows
        )
        total = len(rows)
else:
    series = sweep_promql()
    body = json.dumps({
        "status": "success",
        "data": {
            "resultType": "matrix",
            "result": [
                {"metric": json.loads(k),
                 "values": [[ts, v] for ts, v in sorted(vals.items())]}
                for k, vals in series.items()
            ],
        },
    }, indent=2) + "\n"
    total = sum(len(v) for v in series.values())

if out_path:
    with open(out_path, "w") as fh:
        fh.write(body)
    note(f"wrote {out_path}")
else:
    sys.stdout.write(body)

if summary_path:
    with open(summary_path, "w") as fh:
        json.dump({"start": start, "end": end, "query": query, "chunks": ledger}, fh, indent=2)
    note(f"wrote {summary_path}")

# Leading empty chunks followed by populated ones is the retention horizon, not
# an absence of events. Both stores drop old data silently — no error, no gap in
# the response — so without this the oldest chunk reads as "nothing happened".
ordered = sorted(ledger, key=lambda c: c["start"])


def populated(c):
    return c.get("returned", 0) > 0 or c.get("points", 0) > 0


leading_empty = 0
for c in ordered:
    if populated(c):
        break
    leading_empty += 1
if leading_empty and leading_empty < len(ordered):
    horizon = ordered[leading_empty]["start"]
    note("")
    note(f"note: the first {leading_empty} chunk(s) are empty and later ones are not.")
    note(f"      Data begins at {stamp(horizon)} — treat that as the retention horizon,")
    note("      not as evidence that nothing happened before it.")

failed = [c for c in ledger if c["status"] == "failed"]
degraded = [c for c in ledger if c["status"] == "degraded"]
cached = [c for c in ledger if c.get("cached")]

note("")
note(f"total: {total}  chunks: {len(ledger)}  failed: {len(failed)}  degraded: {len(degraded)}")
if cached:
    note(f"note: {len(cached)} chunk(s) were served from Loki's results cache and under-report")
    note("      lines scanned. The answer is still Loki's, but do not cite a scan count from")
    note("      them — the cache is keyed by aligned splits, so shifting the window only")
    note("      re-scans the edges. Only a range's FIRST query gives a real scan count.")
if failed or degraded:
    note("INCOMPLETE: this sweep is a floor, not a total. Do not quote it as a count.")
    sys.exit(2)
PY
