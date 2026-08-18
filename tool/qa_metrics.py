#!/usr/bin/env python3
"""Parse build/qa/* into metrics.json, then gate it against baseline.json.

Called by `tool/qa.sh perf`. Reads nothing but files already on disk, so it is
safe to re-run for a different verdict without re-measuring:

    QA_BASELINE=1 python3 tool/qa_metrics.py   # adopt this run as the baseline
    python3 tool/qa_metrics.py                 # gate against the baseline

Exit 0 = every gate within budget (or no baseline yet). Exit 1 = regression.
"""

import json
import os
import pathlib
import re
import statistics
import sys

OUT = pathlib.Path('build/qa')
BASELINE = OUT / 'baseline.json'


def med(xs):
    return round(statistics.median(xs), 3) if xs else None


def read(name):
    p = OUT / name
    return p.read_text() if p.exists() else ''


m = {}

# `am start -W` prints "TotalTime: 812" / "WaitTime: 830" per launch.
cold = read('coldstart.txt')
m['cold_start_total_ms'] = med([int(x) for x in re.findall(r'^TotalTime:\s*(\d+)', cold, re.M)])
m['cold_start_wait_ms'] = med([int(x) for x in re.findall(r'^WaitTime:\s*(\d+)', cold, re.M)])

# flutter --trace-startup, micros -> ms, median of the three runs.
startup = [
    json.loads((OUT / f'start_up_info.{n}.json').read_text())
    for n in (1, 2, 3)
    if (OUT / f'start_up_info.{n}.json').exists()
]
for out_key, in_key in (
    ('time_to_first_frame_ms', 'timeToFirstFrameMicros'),
    ('time_to_first_frame_rasterized_ms', 'timeToFirstFrameRasterizedMicros'),
    ('time_to_framework_init_ms', 'timeToFrameworkInitMicros'),
):
    m[out_key] = med([s[in_key] / 1000 for s in startup if in_key in s])

# TimelineSummary.summaryJson, written by test_driver/perf_driver.dart.
ts = OUT / 'dashboard_scroll.timeline_summary.json'
if ts.exists():
    t = json.loads(ts.read_text())
    m['avg_frame_build_ms'] = t['average_frame_build_time_millis']
    m['p90_frame_build_ms'] = t['90th_percentile_frame_build_time_millis']
    m['worst_frame_build_ms'] = t['worst_frame_build_time_millis']
    m['missed_frame_build_budget_count'] = t['missed_frame_build_budget_count']
    m['avg_frame_raster_ms'] = t['average_frame_rasterizer_time_millis']
    m['p90_frame_raster_ms'] = t['90th_percentile_frame_rasterizer_time_millis']
    m['missed_frame_raster_budget_count'] = t['missed_frame_rasterizer_budget_count']
    m['frame_count'] = t['frame_count']

# dumpsys meminfo: "TOTAL PSS: 214000 ..." on Android 10+, bare "TOTAL 214000" before.
mem = read('meminfo.txt')
hit = re.search(r'TOTAL PSS:\s*(\d+)', mem) or re.search(r'^\s*TOTAL\s+(\d+)', mem, re.M)
m['total_pss_kb'] = int(hit.group(1)) if hit else None

m['apk_size_bytes'] = int(os.environ.get('QA_APK_BYTES', 0)) or None

doc = {'metrics': m}
(OUT / 'metrics.json').write_text(json.dumps(doc, indent=2, sort_keys=True) + '\n')

if os.environ.get('QA_BASELINE') == '1':
    BASELINE.write_text(json.dumps(doc, indent=2, sort_keys=True) + '\n')
    print(f'baseline written: {BASELINE}')
    sys.exit(0)

if not BASELINE.exists():
    print(
        f'no {BASELINE} — run `bash tool/qa.sh --baseline perf` once to adopt one.\n'
        'Perf gates counted as PASS (unbaselined) — say so in the report.'
    )
    sys.exit(0)

# pct = relative budget, floor = absolute noise floor. A gate trips only when a
# delta breaches BOTH, so device jitter alone can never flap it: a pure-percent
# gate flaps on small numbers (2ms -> 3ms is +50% and means nothing), a pure
# absolute one flaps on large ones.
GATES = {
    'cold_start_total_ms': (0.15, 150),
    'time_to_first_frame_ms': (0.15, 150),
    'time_to_first_frame_rasterized_ms': (0.15, 150),
    'p90_frame_build_ms': (0.25, 2.0),
    'p90_frame_raster_ms': (0.25, 2.0),
    'missed_frame_build_budget_count': (0.50, 5),
    'missed_frame_raster_budget_count': (0.50, 5),
    'total_pss_kb': (0.15, 20000),
    'apk_size_bytes': (0.03, 500000),
}

base = json.loads(BASELINE.read_text())['metrics']
failed = 0
print(f"{'metric':38} {'baseline':>12} {'now':>12} {'delta':>10}  verdict")
for k, (pct, floor) in GATES.items():
    b, n = base.get(k), m.get(k)
    if b is None or n is None:
        print(f'{k:38} {"-":>12} {"-":>12} {"-":>10}  SKIP')
        continue
    d = n - b
    bad = d > b * pct and d > floor
    failed += bad
    print(f'{k:38} {b:12.1f} {n:12.1f} {d:+10.1f}  {"FAIL" if bad else "ok"}')

print(f'\n{failed} perf gate(s) failed')
sys.exit(1 if failed else 0)
