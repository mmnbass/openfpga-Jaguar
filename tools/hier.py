#!/usr/bin/env python3
"""Crude Verilog module/instance extractor -> hierarchy tree.
Not a parser; good enough to map a netlist-converted design."""
import re, sys, os, collections

ROOT = sys.argv[1]
TOP  = sys.argv[2] if len(sys.argv) > 2 else None

KEYWORDS = set("""module endmodule input output inout wire reg logic assign always
initial begin end if else case casex casez endcase for while parameter localparam
function endfunction task endtask generate endgenerate genvar integer real time
defparam specify endspecify posedge negedge or and not xor nand nor xnor buf bufif0
bufif1 notif0 notif1 pmos nmos cmos tran tranif0 tranif1 rtran supply0 supply1
default signed unsigned automatic return break continue repeat forever disable
always_comb always_ff always_latch unique priority typedef struct enum bit byte
int shortint longint void localparam specparam table endtable primitive
endprimitive wand wor tri tri0 tri1 triand trior trireg scalared vectored
pulldown pullup string const ref inside do final package endpackage import
export interface endinterface modport class endclass virtual extends
""".split())

mod_re  = re.compile(r'^\s*module\s+([A-Za-z_\\][\w$]*)', re.M)
# inst: <type> [#(...)] <name> ( ... );
inst_re = re.compile(
    r'(?<![\w$.])([A-Za-z_\\][\w$]*)\s*(?:#\s*\([^;]*?\)\s*)?([A-Za-z_\\][\w$]*)\s*\(',
    re.S)

def strip(src):
    src = re.sub(r'/\*.*?\*/', ' ', src, flags=re.S)
    src = re.sub(r'//[^\n]*', ' ', src)
    return src

files = []
for dp, dn, fn in os.walk(ROOT):
    if '.git' in dp.split(os.sep): continue
    for f in fn:
        if f.endswith(('.v', '.sv')): files.append(os.path.join(dp, f))

defined = {}      # module -> file
bodies  = {}      # module -> source text
for path in files:
    src = strip(open(path, errors='ignore').read())
    parts = re.split(r'^\s*module\s+', src, flags=re.M)
    for p in parts[1:]:
        name = re.match(r'([A-Za-z_\\][\w$]*)', p)
        if not name: continue
        name = name.group(1)
        body = re.split(r'^\s*endmodule', p, flags=re.M)[0]
        defined[name] = os.path.relpath(path, ROOT)
        bodies[name] = body

children = {}
for m, body in bodies.items():
    # drop the port list of the module itself
    seen = []
    for mt, inst in inst_re.findall(body):
        if mt in KEYWORDS or inst in KEYWORDS: continue
        if mt not in defined: continue
        seen.append((mt, inst))
    children[m] = seen

instantiated = set(mt for v in children.values() for mt, _ in v)
roots = [m for m in defined if m not in instantiated]

def dump(m, depth, path, out, counts):
    kids = children.get(m, [])
    agg = collections.Counter(mt for mt, _ in kids)
    for mt in sorted(agg):
        n = agg[mt]
        out.append("%s%s%s   [%s]" % ("    "*(depth+1), mt,
                                      (" x%d" % n) if n > 1 else "",
                                      defined.get(mt, "?")))
        counts[mt] += n
        if mt in path:            # recursion guard
            out.append("    "*(depth+2) + "(recursive)")
            continue
        if depth < 40:
            dump(mt, depth+1, path | {mt}, out, counts)

targets = [TOP] if TOP else sorted(roots)
for t in targets:
    if t not in defined:
        print("!! not found:", t); continue
    out = ["%s   [%s]" % (t, defined[t])]
    counts = collections.Counter()
    dump(t, 0, {t}, out, counts)
    print("\n".join(out))
    print("\n--- flattened instance counts under %s (%d distinct module types) ---" % (t, len(counts)))
    for mt, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        print("  %-24s %6d" % (mt, n))
