#!/usr/bin/env python3
"""Extract 'Fitter Resource Utilization by Entity' from a Quartus .fit.rpt.

Usage: tools/parse-fit.py <file.fit.rpt> [--under SUBSTR] [--depth N] [--top N]
"""
import sys, argparse

ap = argparse.ArgumentParser()
ap.add_argument("rpt")
ap.add_argument("--under", default=None, help="only rows whose full hierarchy name contains this")
ap.add_argument("--depth", type=int, default=99)
ap.add_argument("--top", type=int, default=0, help="instead: top N rows by ALMs")
ap.add_argument("--by", default="alm", choices=["alm", "m10k", "dsp"])
a = ap.parse_args()

rows, seen = [], set()
lines = open(a.rpt, errors="ignore").read().splitlines()
# The report opens with a table of contents that also mentions the table name,
# so take the occurrence that begins a real table row (starts with ';').
start = next(i for i, l in enumerate(lines)
             if l.startswith(";") and "Fitter Resource Utilization by Entity" in l)
seps = 0
for l in lines[start:]:
    if l.startswith("+-"):
        seps += 1
        if seps >= 3 and rows:
            break          # end of this table
        continue
    if not l.startswith(";"):
        continue
    f = l.split(";")
    if len(f) < 16:
        continue
    raw = f[1]
    if not raw.lstrip().startswith("|"):
        continue
    depth = (len(raw) - len(raw.lstrip()) - 1) // 3
    node = raw.strip().strip("|")
    full = f[15].strip()
    try:
        alm = float(f[2].split()[0]); bram = int(f[10]); m10k = int(f[11]); dsp = int(f[12])
    except Exception:
        continue
    if full in seen:
        continue
    seen.add(full)
    rows.append(dict(depth=depth, node=node, full=full, alm=alm, bram=bram, m10k=m10k, dsp=dsp))

sel = rows
if a.under:
    sel = [r for r in sel if a.under in r["full"]]
if a.top:
    sel = sorted(sel, key=lambda r: -r[a.by])[:a.top]
    hdr = f"top {a.top} by {a.by}"
else:
    sel = [r for r in sel if r["depth"] <= a.depth]
    hdr = f"depth <= {a.depth}"

print(f"{'entity':<56}{'ALMs':>9}{'M10K':>7}{'BRAMbits':>11}{'DSP':>6}   ({hdr})")
print("-" * 95)
for r in sel:
    if r["alm"] < 1 and r["m10k"] == 0 and r["dsp"] == 0:
        continue
    ind = "  " * min(r["depth"], 8)
    print(f"{ind + r['node'][:54 - 2*min(r['depth'],8)]:<56}"
          f"{r['alm']:>9.0f}{r['m10k']:>7}{r['bram']:>11}{r['dsp']:>6}")
