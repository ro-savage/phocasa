#!/usr/bin/env python3
"""multi.py base1.txt [base2.txt ...] -- other.txt [other2.txt ...] [--filter REGEX]

Compares BENCH|/COORD| medians: the mean of the base runs against the mean of the other runs, per line.
Flags (<<) a rise over 5% when the other side's best run is still more than 5% above the base side's worst run.
Harness-only lines (seed, 6a–6k, COLD fetch/touch, etc.) are skipped; see results/wave-2-coordinator.md."""
import re, sys

SKIP = re.compile(r'harness|seed|COLD fetch|\|6[a-k] |COLD touch|COLD first|second touch|\|3[abc] |\|4 search|nothing dirty')

def load(p):
    d = {}
    for l in open(p):
        parts = l.strip().split('|')
        if len(parts) < 3 or 'info' in parts[1:3]:
            continue
        key = parts[1] if parts[0] == 'COORD' else parts[1] + '|' + parts[2]
        m = re.search(r'(?:median_ms|\|ms)=([\d.]+)', l)
        if m:
            d[key] = float(m.group(1))
    return d

args = sys.argv[1:]
flt = ''
if '--filter' in args:
    i = args.index('--filter'); flt = args[i + 1]; del args[i:i + 2]
split = args.index('--')
base = [load(p) for p in args[:split]]
other = [load(p) for p in args[split + 1:]]
keys = list(dict.fromkeys(k for o in other for k in o))
for k in keys:
    if SKIP.search(k) or (flt and not re.search(flt, k)):
        continue
    a = [b[k] for b in base if k in b]; b = [o[k] for o in other if k in o]
    mb = sum(b) / len(b)
    if not a:
        print(f"{k[:84]:84s} {'new':>9s} {mb:9.2f}"); continue
    ma = sum(a) / len(a); d = (mb - ma) / ma * 100 if ma else 0
    flag = ' <<' if d > 5 and ma > 1 and min(b) > max(a) * 1.05 else ''
    print(f"{k[:84]:84s} {ma:9.2f} {mb:9.2f} {d:+7.1f}%  base[{min(a):.1f},{max(a):.1f}] other[{min(b):.1f},{max(b):.1f}]{flag}")
