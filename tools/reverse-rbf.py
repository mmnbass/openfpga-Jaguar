#!/usr/bin/env python3
"""Bit-reverse a Quartus .rbf into the .rbf_r form APF loads.

The Pocket's FPGA loader expects each byte's bits in the opposite order to what
Quartus emits. Equivalent to pocketpublish/reverse.py.

Usage: tools/reverse-rbf.py <in.rbf> <out.rbf_r>
"""
import sys, pathlib

if len(sys.argv) != 3:
    sys.exit(__doc__)

src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
data = src.read_bytes()
table = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))
dst.write_bytes(data.translate(table))
print(f"{src} -> {dst}  ({len(data):,} bytes, bits reversed)")
