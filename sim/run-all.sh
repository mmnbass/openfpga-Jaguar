#!/usr/bin/env bash
# Run every simulation check. Native macOS, no Quartus.
#
#   sim/run-all.sh
#
# SCRATCH controls where build output goes (default /tmp).
set -uo pipefail
cd "$(dirname "$0")/.."
export SCRATCH="${SCRATCH:-/tmp}"
mkdir -p "$SCRATCH"     # a wiped scratch dir otherwise fails every build

WARN="-Wno-fatal -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-MISINDENT -Wno-IMPLICITSTATIC
      -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL
      -Wno-PINCONNECTEMPTY -Wno-UNDRIVEN -Wno-MULTIDRIVEN -Wno-BLKANDNBLK
      -Wno-CASEINCOMPLETE -Wno-LATCH -Wno-UNOPTFLAT -Wno-VARHIDDEN -Wno-SYNCASYNCNET
      -Wno-COMBDLY -Wno-INITIALDLY -Wno-GENUNNAMED -Wno-PINNOTFOUND -Wno-ASCRANGE
      -Wno-UNSIGNED -Wno-IMPLICIT -Wno-WIDTHCONCAT -Wno-SELRANGE"

fail=0

build_run() {   # <name> <top> <files...>
    local name="$1" top="$2"; shift 2
    local obj="$SCRATCH/sim_$name"
    rm -f "$obj/sim_exe"
    # shellcheck disable=SC2086
    verilator --binary --timing -j 4 --error-limit 400 $WARN \
        +define+NO_JAGUAR_CD +incdir+rtl/upstream \
        --top-module "$top" --Mdir "$obj" -o sim_exe "$@" \
        > "$obj.log" 2>&1
    if ! [ -x "$obj/sim_exe" ]; then
        echo "=== $name: BUILD FAILED"
        grep -E "^%Error" "$obj.log" | head -10
        fail=1; return
    fi
    echo "=== $name"
    # nuked-68k resolves its microcode against the working directory.
    mkdir -p "$obj/run"
    ln -sf "$PWD/rtl/upstream/nuked-68k/68k_ucode.txt" "$obj/run/" 2>/dev/null
    ln -sf "$PWD/rtl/upstream/nuked-68k/68k_ncode.txt" "$obj/run/" 2>/dev/null
    ( cd "$obj/run" && "$obj/sim_exe" ) 2>&1 | grep -vE "^- (Verilator|S i m)" | sed 's/^/    /'
}

CORE_FILES="rtl/jaguar_top.sv rtl/upstream/jaguar.v
  rtl/upstream/Tom/*.v rtl/upstream/Jerry/*.v rtl/upstream/jaguar_common/*.v
  rtl/upstream/nuked-68k/68k.v rtl/upstream/eeprom_93c46_x16.v
  rtl/upstream/jag_controller_mux.v rtl/upstream/jag_team_tap.v
  rtl/upstream/gamedrive.v rtl/upstream/ps2_mouse.v rtl/upstream/tda1545a.v
  rtl/upstream/jag_lightgun.sv rtl/upstream/mem/sdram_dual.sv rtl/sram_cache.sv rtl/blkcache.sv
  sim/stubs.sv sim/altsyncram_model.sv sim/sdram_model.sv"

# shellcheck disable=SC2086
build_run jaguar_video tb_jaguar_video target/pocket/jaguar_video.sv sim/tb_jaguar_video.sv
# shellcheck disable=SC2086
build_run sdram_ch1 tb_sdram_ch1 rtl/upstream/mem/sdram_dual.sv sim/stubs.sv sim/sdram_model.sv sim/tb_sdram_ch1.sv
# SRAM probe v2 against a 12 ns model: all eight latencies clean
# shellcheck disable=SC2086
build_run sram_probe tb_sram_probe target/pocket/sram_probe.sv sim/tb_sram_probe.sv
# Controller mapping and keypad layer
# shellcheck disable=SC2086
build_run pad_map tb_pad_map target/pocket/pad_map.sv sim/tb_pad_map.sv
# shellcheck disable=SC2086
build_run loader_slots tb_loader_slots $CORE_FILES sim/tb_loader_slots.sv
# shellcheck disable=SC2086
build_run boot tb_jaguar_boot $CORE_FILES sim/tb_jaguar_boot.sv

echo
[ $fail -eq 0 ] && echo "all simulations built and ran" || echo "SOME SIMULATIONS FAILED TO BUILD"
exit $fail
