#!/usr/bin/env bash
# Lint the whole Pocket design, deriving the file list from the .qip files that
# Quartus actually reads, and check that every file a .qip references exists.
#
# WHAT THIS DOES NOT CATCH -- read this before trusting it:
#
# A module that is INSTANTIATED but MISSING FROM THE .qip will still pass here.
# Verilator auto-resolves a module from <name>.v / <name>.sv found in any
# include path *or in the directory of any file on its command line*, and there
# is no flag to turn that off. This is exactly how sound_i2s's dependency on
# sync_fifo.sv slipped past a green local lint and failed in Quartus with
# "Node instance sync_fifo instantiates undefined entity sync_fifo".
#
# For that class of error the authority is quartus_map, via
# .github/workflows/m1-map.yml -- roughly a 3 minute round trip. Do not treat
# a PASS here as meaning the design will synthesise.
#
# It also does not catch port-direction mistakes: Verilator accepted assigning
# to an input port, which Quartus rejects with Error (10231). See docs/09.
#
# Altera megafunctions (altsyncram, dcfifo, altera_pll, altddio_out) cannot be
# resolved by Verilator; they are expected unresolved and filtered out.
#
# NOTE: +incdir+ also acts as Verilator's module search path, so it is kept to
# the single directory that genuinely needs it (rtl/upstream, for
# `include "defines.vh"`). Adding target/pocket or platform/pocket here would
# let Verilator auto-resolve modules missing from the .qip and silently defeat
# the whole point of this script.
set -uo pipefail
cd "$(dirname "$0")/.."

command -v verilator >/dev/null || { echo "error: verilator not installed" >&2; exit 1; }

# Expand a .qip into the source files it declares, following nested QIP_FILEs.
expand_qip() {
    local qip="$1" dir
    dir="$(dirname "$qip")"
    [ -f "$qip" ] || return 0
    sed -e 's/#.*//' "$qip" \
      | grep -oE '(VERILOG_FILE|SYSTEMVERILOG_FILE|VHDL_FILE|QIP_FILE)[[:space:]]+\[file join \$::quartus\(qip_path\)[[:space:]]+[^]]+\]|(VERILOG_FILE|SYSTEMVERILOG_FILE|VHDL_FILE|QIP_FILE)[[:space:]]+[^[:space:]]+' \
      | while read -r kind rest; do
            local f
            f=$(echo "$rest" | sed -E 's/.*qip_path\)[[:space:]]*//; s/[[:space:]]*\]$//; s/^"//; s/"$//')
            [ -z "$f" ] && continue
            case "$kind" in
                QIP_FILE) expand_qip "$dir/$f" ;;
                VHDL_FILE) ;;                       # Verilator cannot read VHDL
                *) echo "$dir/$f" ;;
            esac
        done
}

# QIPS selects the build to lint (default: the Jaguar core). For the
# diagnostic builds: QIPS=target/pocket/post.qip or QIPS=target/pocket/sweep.qip
QIPS="${QIPS:-target/pocket/core.qip rtl/jaguar_pocket.qip}"
FILES=$( for q in $QIPS; do expand_qip "$q"; done | sort -u )
MISSING=$(for f in $FILES; do [ -f "$f" ] || echo "$f"; done)
if [ -n "$MISSING" ]; then
    echo "error: .qip references files that do not exist:" >&2
    echo "$MISSING" >&2
    exit 1
fi

echo "linting $(echo "$FILES" | wc -l | tr -d ' ') files derived from the .qip set"

# Stubs for things Verilator cannot see: the VHDL dpram/spram in bram.vhd, plus
# the Altera primitives.
cat > /tmp/pocket_lint_stubs.sv <<'STUB'
// Stand-in for the VHDL spram in rtl/upstream/mem/bram.vhd, which Verilator
// cannot read. dpram is stubbed in sim/stubs.sv.
module spram #(parameter ADDR_WIDTH=8, parameter DATA_WIDTH=8,
               parameter MEM_NAME="") (input wire clock,
    input wire [ADDR_WIDTH-1:0] address, input wire [DATA_WIDTH-1:0] data,
    input wire wren, output wire [DATA_WIDTH-1:0] q);
  assign q = '0;
endmodule
STUB

OUT=$(verilator --lint-only -Wno-fatal --error-limit 2000 \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-MISINDENT -Wno-IMPLICITSTATIC \
    -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
    -Wno-PINCONNECTEMPTY -Wno-UNDRIVEN -Wno-MULTIDRIVEN -Wno-BLKANDNBLK \
    -Wno-CASEINCOMPLETE -Wno-LATCH -Wno-UNOPTFLAT -Wno-VARHIDDEN \
    -Wno-SYNCASYNCNET -Wno-COMBDLY -Wno-INITIALDLY -Wno-GENUNNAMED \
    -Wno-PINNOTFOUND \
    --timing +define+NO_JAGUAR_CD \
    +incdir+rtl/upstream \
    --top-module core_top \
    $FILES $(expand_qip platform/pocket/apf.qip) \
    sim/stubs.sv /tmp/pocket_lint_stubs.sv 2>&1)

# Altera primitives are expected to be unresolved; everything else is ours.
MEGA='altsyncram|dcfifo|altera_pll|altddio_out'
# "Cannot find file containing module" is the error class that caught us
# (sync_fifo missing from core.qip while the local lint passed).
MODMISSING=$(echo "$OUT" \
    | grep -E "Cannot find file containing module|refers to missing module" \
    | grep -vE "$MEGA" | sed 's/.*module[^:]*: *//' | sort -u)
OTHER=$(echo "$OUT" | grep '^%Error' \
    | grep -vE "$MEGA|too many errors|Cannot find file containing module|refers to missing module|Exiting due to")

echo "--- unresolved modules ---"
if [ -n "$MODMISSING" ]; then echo "$MODMISSING"; else echo "    none"; fi
echo "--- other errors ---"
if [ -n "$OTHER" ]; then echo "$OTHER" | head -25; else echo "    none"; fi

[ -z "$MODMISSING" ] && [ -z "$OTHER" ] && { echo "PASS"; exit 0; }
echo "FAIL"; exit 1
