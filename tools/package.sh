#!/usr/bin/env bash
# Build the installable openFPGA package from a Quartus .rbf.
#
#   tools/package.sh <path-to-jaguar_pocket.rbf> [version]
#
# The .rbf comes from the m2-fit workflow artifact (projects/output_files/).
# Produces dist/mmnbass.Jaguar_<version>.zip laid out for the Pocket SD
# card: Assets/, Cores/, Platforms/.
set -euo pipefail
cd "$(dirname "$0")/.."

RBF="${1:-}"
VER="${2:-0.0.1}"
[ -f "${RBF:-}" ] || { echo "usage: tools/package.sh <jaguar_pocket.rbf> [version]" >&2; exit 2; }

CORE="mmnbass.Jaguar"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R pkg/pocket/* "$STAGE/"
# Stamp the version and today's date into core.json so the Pocket's core info
# shows what was actually built (it said 0.0.1 / 2026-10-02 before this).
python3 - "$STAGE/Cores/$CORE/core.json" "$VER" <<'PY'
import json, sys, datetime
p, ver = sys.argv[1], sys.argv[2]
d = json.load(open(p))
md = d["core"]["metadata"]
md["version"] = ver
md["date_release"] = datetime.date.today().isoformat()
json.dump(d, open(p, "w"), indent=2)
PY
python3 tools/reverse-rbf.py "$RBF" "$STAGE/Cores/$CORE/bitstream.rbf_r"
mkdir -p "$STAGE/Assets/jaguar/common" dist

# The boot ROM is deliberately NOT shipped.
cat > "$STAGE/Assets/jaguar/common/PUT_ROMS_HERE.txt" <<'TXT'
Place Jaguar cartridge images here (.jag .j64 .rom .bin).

You must also supply the Jaguar boot ROM as:

    Assets/jaguar/common/jagboot.rom

It is NOT included. MiSTer and the Pocket GBA core have the same requirement.
TXT

ZIP="dist/${CORE}_${VER}.zip"
rm -f "$ZIP"
( cd "$STAGE" && zip -qr "$OLDPWD/$ZIP" . -x ".*" )
echo "built $ZIP"
unzip -l "$ZIP" | tail -5
