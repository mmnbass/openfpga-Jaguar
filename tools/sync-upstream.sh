#!/usr/bin/env bash
# Vendor the upstream sources into the tree so builds are reproducible and CI
# needs no extra clones.
#
#   rtl/upstream/     <- refs/Jaguar_MiSTer/rtl/          (GPL-2.0-or-later)
#   platform/pocket/  <- refs/core-template/src/fpga/apf/ (Analogue APF)
#   target/pocket/    <- selected modules from refs/openfpga-SNES (MIT)
#
# rtl/upstream/ is NEVER hand-edited. Changes that must touch upstream RTL go in
# patches/ (listed in UPSTREAM.txt), so re-syncing stays possible.
set -euo pipefail
cd "$(dirname "$0")/.."

for d in Jaguar_MiSTer core-template openfpga-SNES; do
    [ -d "refs/$d/.git" ] || { echo "error: refs/$d missing; run tools/fetch-refs.sh" >&2; exit 1; }
done

stamp() { git -C "refs/$1" log -1 --format='%H  %ad  %s' --date=short; }

echo "== rtl/upstream  <- Jaguar_MiSTer/rtl"
rm -rf rtl/upstream && mkdir -p rtl
cp -R refs/Jaguar_MiSTer/rtl rtl/upstream
# Quartus-generated PLL wrappers target MiSTer's 50 MHz reference; the Pocket
# build generates its own from clk_74b (docs/03). Drop them to avoid confusion.
rm -rf rtl/upstream/pll rtl/upstream/pll.qip rtl/upstream/pll.v
# MiSTer DDR3 Avalon master; Pocket has no DDR3 (docs/04).
rm -f rtl/upstream/mem/ddram.sv

echo "== platform/pocket  <- core-template APF (verbatim, never edited)"
rm -rf platform/pocket && mkdir -p platform/pocket
cp refs/core-template/src/fpga/apf/* platform/pocket/

echo "== target/pocket  <- openfpga-SNES support modules (MIT)"
mkdir -p target/pocket
for f in data_loader.sv data_unloader.sv sound_i2s.sv psram.sv sync_fifo.sv; do
    cp "refs/openfpga-SNES/target/pocket/$f" target/pocket/
done
cp refs/core-template/src/fpga/core/core_bridge_cmd.v target/pocket/

# Re-apply our upstream deltas. Keep these few and small.
if compgen -G "patches/*.patch" > /dev/null; then
    echo "== applying patches/"
    for pf in patches/*.patch; do
        printf '   %s ... ' "$(basename "$pf")"
        if patch -p0 -s --forward < "$pf"; then echo "ok"; else echo "FAILED"; exit 1; fi
    done
fi


{
    echo "# Vendored upstream revisions"
    echo "#"
    echo "# Regenerate with tools/sync-upstream.sh. Do not hand-edit rtl/upstream/."
    echo
    echo "Jaguar_MiSTer  $(stamp Jaguar_MiSTer)"
    echo "core-template  $(stamp core-template)"
    echo "openfpga-SNES  $(stamp openfpga-SNES)"
    echo
    echo "Patches applied:"
    for pf in patches/*.patch; do [ -e "$pf" ] && echo "  $(basename "$pf")"; done
    echo
    echo "Removed from rtl/upstream/ on sync:"
    echo "  pll.qip, pll.v, pll/   - MiSTer 50 MHz PLL; Pocket generates its own (docs/03)"
    echo "  mem/ddram.sv           - DDR3 Avalon master; Pocket has no DDR3 (docs/04)"
} > UPSTREAM.txt

echo
cat UPSTREAM.txt
