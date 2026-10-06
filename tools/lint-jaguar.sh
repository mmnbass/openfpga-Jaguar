#!/usr/bin/env bash
# Elaborate the Jaguar console core with Verilator, in both CD and cart-only
# configurations. Runs natively on macOS; no Quartus required.
#
# EXPECTED RESULT: the only errors are
#   "Dotted reference to instance that refers to missing module: 'altsyncram'"
# in exactly three files -- Tom/ab8016a.v, Tom/ab8616a.v, jaguar_common/aba032a.v.
# Those are live Altera megafunction instances and resolve under Quartus.
#
# Usage: tools/lint-jaguar.sh [path-to-rtl]        (default rtl/upstream)
set -uo pipefail
cd "$(dirname "$0")/.."
RTL="${1:-rtl/upstream}"

[ -f "$RTL/jaguar.v" ] || { echo "error: $RTL/jaguar.v not found" >&2; exit 1; }
command -v verilator >/dev/null || { echo "error: verilator not installed" >&2; exit 1; }

run() {
    local label="$1"; shift
    local out rc=0
    out=$(verilator --lint-only -Wno-fatal \
        -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-MISINDENT -Wno-IMPLICITSTATIC --timing \
        "$@" \
        +incdir+"$RTL" +incdir+"$RTL/Tom" +incdir+"$RTL/Jerry" \
        +incdir+"$RTL/jaguar_common" +incdir+"$RTL/Butch" +incdir+"$RTL/fx68k" \
        +incdir+"$RTL/nuked-68k" \
        --top-module jaguar \
        "$RTL/jaguar.v" \
        "$RTL"/Tom/*.v "$RTL"/Jerry/*.v "$RTL"/jaguar_common/*.v "$RTL"/Butch/*.v \
        "$RTL"/nuked-68k/68k.v \
        "$RTL"/eeprom_93c46_x16.v "$RTL"/jag_controller_mux.v "$RTL"/jag_team_tap.v \
        "$RTL"/gamedrive.v "$RTL"/ps2_mouse.v "$RTL"/tda1545a.v "$RTL"/jag_lightgun.sv \
        "$RTL"/fx68k/fx68k.sv "$RTL"/fx68k/fx68kAlu.sv "$RTL"/fx68k/uaddrPla.sv \
        2>&1)
    local bad
    bad=$(echo "$out" | grep '^%Error' | grep -v "altsyncram" | grep -v "too many errors")
    echo "--- $label"
    echo "$out" | grep '^%Error' | grep altsyncram \
        | sed 's/^%Error: \([^:]*\):.*/    altsyncram in \1/' | sort | uniq -c
    if [ -n "$bad" ]; then
        echo "$bad" | head -20
        echo "    FAIL: unexpected errors"
        rc=1
    else
        echo "    PASS"
    fi
    return $rc
}

fail=0
run "with Jaguar CD (default)"           || fail=1
run "cart-only (-DNO_JAGUAR_CD)" +define+NO_JAGUAR_CD || fail=1
exit $fail
