#!/usr/bin/env bash
# Q6: simulate rtl/mem/sdram_dual.sv to validate the cycle counts in
# docs/04-memory.md §4.3. Runs natively on macOS; no Quartus required.
set -euo pipefail
cd "$(dirname "$0")/.."
RTL="${1:-refs/Jaguar_MiSTer/rtl}"
OBJ="${SCRATCH:-/tmp}/jag_sdram_tb"
command -v verilator >/dev/null || { echo "error: verilator not installed" >&2; exit 1; }
[ -f "$RTL/mem/sdram_dual.sv" ] || { echo "error: run tools/fetch-refs.sh first" >&2; exit 1; }

verilator --binary --timing -j 0 \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
  -Wno-MULTIDRIVEN -Wno-INITIALDLY -Wno-BLKANDNBLK -Wno-LATCH -Wno-UNSIGNED \
  -Wno-IMPLICIT -Wno-SYNCASYNCNET -Wno-COMBDLY -Wno-TIMESCALEMOD -Wno-IMPLICITSTATIC -Wno-DECLFILENAME -Wno-VARHIDDEN \
  --top-module tb_sdram_ch1 \
  --Mdir "$OBJ" -o tb_sdram_ch1 \
  "$RTL/mem/sdram_dual.sv" sim/stubs.sv sim/sdram_model.sv sim/tb_sdram_ch1.sv \
  2>&1 | grep -vE "^%Warning|^\s+[0-9]+ \||^\s+\^|^\s+:|^\s*$" | head -30

"$OBJ/tb_sdram_ch1"
