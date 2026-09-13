#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

start_date=""
days="3"
timezone="America/Toronto"
out_dir="$SCRIPT_DIR/out"
prefix=""
config_name="overview"

usage() {
  cat <<'USAGE'
Usage: report.sh --start-date YYYY-MM-DD [options]

Generate a Grafana event report from Prometheus data. The sections, metrics, and
labels are driven by a report definition (JSON), so the engine itself carries no
site-specific queries.

Report definitions load from:
  1. $GRAFANA_QUERY_REPORTS_DIR/<config>.json, if that env var is set
  2. reports/local/<config>.json    (gitignored — your team's real definition)
  3. ~/.config/grafana-tools/reports/<config>.json (survives plugin updates)
  4. reports/example/<config>.json   (committed generic example; the fallback)

Options:
  --start-date <date>   Inclusive start date in YYYY-MM-DD (required).
  --days <count>        Number of days to include. Default: 3.
  --timezone <tz>       IANA timezone. Default: America/Toronto.
  --config <name>       Report definition to use. Default: overview.
  --out-dir <path>      Output directory. Default: ./out
  --prefix <name>       File prefix for outputs.
  --help                Show this help text.

Outputs (in --out-dir):
  <prefix>.md, <prefix>.json, and a CSV per section marked "csv": true.

Examples:
  ./report.sh --start-date 2026-04-23
  ./report.sh --start-date 2026-04-23 --days 3 --config overview --prefix launch
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start-date) start_date="$2"; shift 2 ;;
    --days) days="$2"; shift 2 ;;
    --timezone) timezone="$2"; shift 2 ;;
    --config) config_name="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --prefix) prefix="$2"; shift 2 ;;
    --help) usage; exit 0 ;;
    --*) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    *) printf 'Unexpected argument: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$start_date" ]]; then
  printf '--start-date is required.\n' >&2
  usage >&2
  exit 1
fi

if ! [[ "$days" =~ ^[0-9]+$ ]] || [[ "$days" -lt 1 ]]; then
  printf '--days must be a positive integer.\n' >&2
  exit 1
fi

# Resolve the report definition file.
config_reports="${XDG_CONFIG_HOME:-$HOME/.config}/grafana-tools/reports"
if [[ -n "${GRAFANA_QUERY_REPORTS_DIR:-}" ]]; then
  config_file="$GRAFANA_QUERY_REPORTS_DIR/$config_name.json"
elif [[ -f "$SCRIPT_DIR/reports/local/$config_name.json" ]]; then
  config_file="$SCRIPT_DIR/reports/local/$config_name.json"
elif [[ -f "$config_reports/$config_name.json" ]]; then
  config_file="$config_reports/$config_name.json"
else
  config_file="$SCRIPT_DIR/reports/example/$config_name.json"
fi

if [[ ! -f "$config_file" ]]; then
  printf 'Report definition not found: %s\n' "$config_file" >&2
  printf 'Available definitions:\n' >&2
  ls "$SCRIPT_DIR"/reports/local/*.json "$config_reports"/*.json \
     "$SCRIPT_DIR"/reports/example/*.json 2>/dev/null >&2 || true
  exit 1
fi

python3 - "$SCRIPT_DIR" "$start_date" "$days" "$timezone" "$out_dir" "$prefix" "$config_file" <<'PY'
import csv
import json
import re
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

SCRIPT_DIR = Path(sys.argv[1])
start_date_str = sys.argv[2]
days = int(sys.argv[3])
timezone = sys.argv[4]
out_dir = Path(sys.argv[5]).expanduser()
prefix = sys.argv[6].strip()
config_path = Path(sys.argv[7])

cfg = json.loads(config_path.read_text())
report_title = cfg.get("title", "Grafana Report")
sections = cfg.get("sections", [])

try:
    tz = ZoneInfo(timezone)
except Exception as exc:
    raise SystemExit(f"Invalid timezone: {timezone}: {exc}")

try:
    start_date = datetime.strptime(start_date_str, "%Y-%m-%d").date()
except ValueError:
    raise SystemExit("--start-date must use YYYY-MM-DD")

window_start = datetime(start_date.year, start_date.month, start_date.day, tzinfo=tz)
window_end = window_start + timedelta(days=days)
window_end_ts = int(window_end.timestamp())
window_hours = days * 24

if not prefix:
    prefix = f"report-{window_start.date().isoformat()}-to-{(window_end - timedelta(days=1)).date().isoformat()}"

out_dir.mkdir(parents=True, exist_ok=True)

promql_script = SCRIPT_DIR / "promql.sh"
if not promql_script.exists():
    raise SystemExit(f"Missing helper: {promql_script}")

sweep_script = SCRIPT_DIR / "sweep.sh"

day_windows = []
for i in range(days):
    ds = window_start + timedelta(days=i)
    de = ds + timedelta(days=1)
    day_windows.append({
        "label": ds.strftime("%a %Y-%m-%d"),
        "date": ds.date().isoformat(),
        "start_ts": int(ds.timestamp()),
        "end_ts": int(de.timestamp()),
    })
labels = [d["label"] for d in day_windows]


def render(template, w=None, ts=None):
    """Substitute query tokens. PromQL braces are left untouched."""
    s = template
    if w is not None:
        s = s.replace("__W__", str(w))
    if ts is not None:
        s = s.replace("__TS__", str(ts))
    return s


def run_promql(query, start=None, end=None, step="60s"):
    cmd = [str(promql_script)]
    if start is not None or end is not None:
        cmd.extend(["--start", str(start), "--end", str(end), "--step", step])
    cmd.append(query)
    proc = subprocess.run(cmd, cwd=SCRIPT_DIR, text=True, capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "promql.sh failed")
    payload = json.loads(proc.stdout)
    if payload.get("status") != "success":
        raise RuntimeError(f"Prometheus query failed: {payload}")
    return payload


def vector_sum(query):
    total = 0.0
    for row in run_promql(query).get("data", {}).get("result", []):
        if "value" in row:
            total += float(row["value"][1])
        elif row.get("values"):
            total += float(row["values"][-1][1])
    return total


def vector_rows(query):
    rows = []
    for row in run_promql(query).get("data", {}).get("result", []):
        if "value" in row:
            v = float(row["value"][1])
        elif row.get("values"):
            v = float(row["values"][-1][1])
        else:
            continue
        rows.append((row.get("metric", {}), v))
    return rows


def range_max(query, start, end_exclusive, step="300s"):
    payload = run_promql(query, start=start, end=end_exclusive - 1, step=step)
    max_v = None
    for row in payload.get("data", {}).get("result", []):
        for _, raw in row.get("values", []):
            v = float(raw)
            if max_v is None or v > max_v:
                max_v = v
    return 0.0 if max_v is None else max_v


def log_count(selector, start_ts, end_ts, chunk="6h", limit=5000):
    """Count matching log lines over a window.

    Goes through sweep.sh in "agg" mode: counting server-side with
    count_over_time returns a number rather than lines, so it is far cheaper
    than pulling them and the --limit truncation cannot apply. sweep halves any
    chunk the gateway refuses, so a wide window degrades into more queries
    rather than into a 502 that reads as zero. Returns (count, complete).
    """
    if not sweep_script.exists():
        raise SystemExit(f"Missing helper: {sweep_script} (log sections need it)")
    proc = subprocess.run(
        [str(sweep_script), "--type", "logql", "--start", str(start_ts),
         "--end", str(end_ts), "--chunk", chunk, "--limit", str(limit),
         "--mode", "agg", selector],
        cwd=SCRIPT_DIR, text=True, capture_output=True,
    )
    # 2 means some chunk failed or stayed capped: the total is a floor, which the
    # report has to disclose rather than print as a count.
    if proc.returncode not in (0, 2):
        raise RuntimeError(proc.stderr.strip() or "sweep.sh failed")
    total = 0
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line:
            total += json.loads(line)["count"]
    return total, proc.returncode == 0


def fmt_int(v):
    return f"{int(round(v)):,}"


def fmt_value(v, kind):
    if kind == "pct":
        return f"{v:.3f}%"
    if kind == "seconds":
        return f"{v:.3f}s"
    if kind == "float":
        return f"{v:.2f}"
    return fmt_int(v)


def slugify(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "section"


def label_key(metric):
    return "/".join(str(v) for _, v in sorted(metric.items())) or "<all>"


lines = [f"# {report_title}", ""]
lines.append(
    f"Window: **{window_start.date().isoformat()} through {(window_end - timedelta(days=1)).date().isoformat()}** (`{timezone}`)."
)
lines.append("")
lines.append("_Daily columns use `increase(...[24h] @ day_end)`; window totals use a single `[Nh] @ window_end` window; `daily max` rows are the per-day peak of a range query._")
lines.append("")

artifact_sections = []
csv_paths = []

for sec in sections:
    kind = sec.get("kind", "scalar")
    title = sec.get("title", kind)
    lines.append(f"## {title}")

    if kind == "scalar":
        computed = []
        for m in sec.get("metrics", []):
            day_vals = [vector_sum(render(m["query"], 24, d["end_ts"])) for d in day_windows]
            total = vector_sum(render(m["query"], window_hours, window_end_ts))
            computed.append({"label": m["label"], "fmt": m.get("fmt", "int"), "days": day_vals, "total": total})
        lines.append("| Metric | " + " | ".join(labels) + " | Window Total |")
        lines.append("|---|" + "|".join(["---:"] * (len(labels) + 1)) + "|")
        for r in computed:
            cells = [fmt_value(v, r["fmt"]) for v in r["days"]] + [fmt_value(r["total"], r["fmt"])]
            lines.append(f"| {r['label']} | " + " | ".join(cells) + " |")
        artifact_sections.append({"kind": kind, "title": title, "metrics": computed})

    elif kind == "range_max":
        computed = []
        for m in sec.get("metrics", []):
            day_vals = [range_max(render(m["query"]), d["start_ts"], d["end_ts"]) for d in day_windows]
            computed.append({"label": m["label"], "fmt": m.get("fmt", "float"), "days": day_vals})
        lines.append("| Metric (daily max) | " + " | ".join(labels) + " |")
        lines.append("|---|" + "|".join(["---:"] * len(labels)) + "|")
        for r in computed:
            cells = [fmt_value(v, r["fmt"]) for v in r["days"]]
            lines.append(f"| {r['label']} | " + " | ".join(cells) + " |")
        artifact_sections.append({"kind": kind, "title": title, "metrics": computed})

    elif kind == "topn":
        n = int(sec.get("top", 10))
        fmt_kind = sec.get("fmt", "int")
        rows = vector_rows(render(sec["query"], window_hours, window_end_ts))
        rows.sort(key=lambda mv: mv[1], reverse=True)
        lines.append(f"| {sec.get('item_label', 'Item')} | Value |")
        lines.append("|---|---:|")
        for metric, value in rows[:n]:
            lines.append(f"| `{label_key(metric)}` | {fmt_value(value, fmt_kind)} |")
        artifact_sections.append({
            "kind": kind,
            "title": title,
            "rows": [{"item": label_key(m), "value": v} for m, v in rows],
        })
        if sec.get("csv"):
            csv_path = out_dir / f"{prefix}-{slugify(title)}.csv"
            with csv_path.open("w", newline="") as f:
                writer = csv.writer(f)
                writer.writerow(["item", "value"])
                for metric, value in rows:
                    writer.writerow([label_key(metric), f"{value:.6f}"])
            csv_paths.append(csv_path)

    elif kind == "log_scalar":
        chunk = sec.get("chunk", "6h")
        limit = int(sec.get("limit", 5000))
        computed = []
        any_incomplete = False
        for m in sec.get("metrics", []):
            day_vals, day_complete = [], []
            for d in day_windows:
                v, ok = log_count(m["selector"], d["start_ts"], d["end_ts"], chunk, limit)
                day_vals.append(float(v))
                day_complete.append(ok)
                any_incomplete = any_incomplete or not ok
            computed.append({
                "label": m["label"], "fmt": m.get("fmt", "int"),
                "days": day_vals, "complete": day_complete,
                "total": float(sum(day_vals)),
                "total_complete": all(day_complete),
            })
        lines.append("| Log lines | " + " | ".join(labels) + " | Window Total |")
        lines.append("|---|" + "|".join(["---:"] * (len(labels) + 1)) + "|")
        for r in computed:
            cells = [
                fmt_value(v, r["fmt"]) + ("" if ok else " †")
                for v, ok in zip(r["days"], r["complete"])
            ]
            cells.append(fmt_value(r["total"], r["fmt"]) + ("" if r["total_complete"] else " †"))
            lines.append(f"| {r['label']} | " + " | ".join(cells) + " |")
        if any_incomplete:
            lines.append("")
            lines.append("_† incomplete sweep — a chunk failed or stayed capped, so that figure is a floor, not a count._")
        artifact_sections.append({"kind": kind, "title": title, "metrics": computed})

    else:
        raise SystemExit(
            f"Unknown section kind: {kind!r} (expected scalar, range_max, topn, or log_scalar)"
        )

    lines.append("")

md_path = out_dir / f"{prefix}.md"
md_path.write_text("\n".join(lines) + "\n")

json_path = out_dir / f"{prefix}.json"
json_path.write_text(json.dumps({
    "meta": {
        "title": report_title,
        "start_date": start_date_str,
        "days": days,
        "timezone": timezone,
        "window_end_ts": window_end_ts,
        "config": str(config_path),
    },
    "days": day_windows,
    "sections": artifact_sections,
}, indent=2, sort_keys=True))

print(f"Wrote markdown report: {md_path}")
print(f"Wrote JSON artifact:   {json_path}")
for p in csv_paths:
    print(f"Wrote CSV:             {p}")
PY
