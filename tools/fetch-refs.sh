#!/usr/bin/env bash
# Fetch the reference repositories into refs/ (gitignored).
#
#   Jaguar_MiSTer   — the source project being ported
#   core-template   — Analogue's official openFPGA core template (APF + pins)
#   openfpga-SNES   — reference MiSTer -> Pocket port (the "Rosetta Stone")
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p refs

clone() {
    local url="$1" dir="refs/$2"
    if [ -d "$dir/.git" ]; then
        echo "== $2: already present, fetching"
        git -C "$dir" fetch --depth 1 origin 2>&1 | tail -2 || true
    else
        echo "== $2: cloning"
        git clone --depth 1 "$url" "$dir"
    fi
    printf '   %s @ %s\n' "$2" "$(git -C "$dir" log -1 --format='%h %ad %s' --date=short)"
}

clone https://github.com/MiSTer-devel/Jaguar_MiSTer.git  Jaguar_MiSTer
clone https://github.com/open-fpga/core-template.git     core-template
clone https://github.com/agg23/openfpga-SNES.git         openfpga-SNES

echo
echo "Done. Note: spiritualized1997/openFPGA-GBA is deliberately NOT fetched —"
echo "that repository contains only a README, no HDL."
