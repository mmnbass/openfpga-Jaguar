#!/usr/bin/env bash
# Build and run the full-core boot simulation. Runs natively on macOS.
#
# nuked-68k loads its microcode with $readmemb() using bare filenames, which
# Quartus resolves via SEARCH_PATH. The simulator resolves them against the
# working directory, so the run happens in a staging dir with those files
# symlinked in -- without them the 68000 has no microcode and simply never
# fetches, which looks exactly like a design failure.
set -euo pipefail
cd "$(dirname "$0")/.."

OBJ="${SCRATCH:-/tmp}/jagsim"
RUN="$OBJ/run"
command -v verilator >/dev/null || { echo "error: verilator not installed" >&2; exit 1; }

rm -f "$OBJ/sim_exe"      # so a failed build cannot silently re-run a stale one

verilator --binary --timing -j 4 -Wno-fatal --error-limit 300 \
  -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-MISINDENT -Wno-IMPLICITSTATIC -Wno-DECLFILENAME \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY -Wno-UNDRIVEN \
  -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-CASEINCOMPLETE -Wno-LATCH -Wno-UNOPTFLAT -Wno-VARHIDDEN \
  -Wno-SYNCASYNCNET -Wno-COMBDLY -Wno-INITIALDLY -Wno-GENUNNAMED -Wno-PINNOTFOUND -Wno-ASCRANGE \
  +define+NO_JAGUAR_CD ${DEFINES:-} +incdir+rtl/upstream \
  --top-module "${TOP:-tb_jaguar_boot}" --Mdir "$OBJ" -o sim_exe \
  rtl/jaguar_top.sv rtl/upstream/jaguar.v \
  rtl/upstream/Tom/*.v rtl/upstream/Jerry/*.v rtl/upstream/jaguar_common/*.v \
  rtl/upstream/nuked-68k/68k.v rtl/upstream/eeprom_93c46_x16.v \
  rtl/upstream/jag_controller_mux.v rtl/upstream/jag_team_tap.v rtl/upstream/gamedrive.v \
  rtl/upstream/ps2_mouse.v rtl/upstream/tda1545a.v rtl/upstream/jag_lightgun.sv \
  rtl/upstream/mem/sdram_dual.sv rtl/sram_cache.sv rtl/blkcache.sv \
  target/pocket/jaguar_video.sv \
  sim/stubs.sv sim/altsyncram_model.sv sim/sdram_model.sv "sim/${TB:-tb_jaguar_boot}.sv" \
  2>&1 | tee "${OBJ}.buildlog" | grep -E "^%Error|Verilator: Built" || true

if ! [ -x "$OBJ/sim_exe" ]; then
    echo "BUILD FAILED -- not running. Errors:" >&2
    grep -E "^%Error" "${OBJ}.buildlog" | head -20 >&2
    exit 1
fi

mkdir -p "$RUN"
for f in rtl/upstream/nuked-68k/68k_ucode.txt rtl/upstream/nuked-68k/68k_ncode.txt; do
    ln -sf "$PWD/$f" "$RUN/$(basename "$f")"
done

cd "$RUN"
exec "$OBJ/sim_exe" "$@"
