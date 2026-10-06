#!/usr/bin/env bash
# Run a Quartus command inside the raetro/quartus Docker image.
#
# Quartus does not run natively on macOS. This wrapper mounts the repository at
# /build and runs the requested quartus_* command there.
#
# The image is linux/amd64. On Apple Silicon it is translated by Rosetta inside
# an ARM VM -- correct, and far faster than a full QEMU x86 VM. Do NOT use
# `colima start --arch x86_64`: that forces vmType qemu and full CPU emulation.
#
# Needs ~15 GB of free disk for the extracted image. Recommended host setup:
#
#     brew install colima docker
#     colima start --vm-type vz --rosetta --cpu 8 --memory 12 --disk 80
#
# Use this for quartus_map iteration; use GitHub Actions (x86 runners) for
# authoritative quartus_fit / quartus_sta runs. See docs/10-staged-plan.md.
#
# Examples:
#   tools/quartus.sh quartus_sh --version
#   tools/quartus.sh quartus_map  projects/jaguar_pocket -c jaguar_pocket
#   tools/quartus.sh quartus_fit  projects/jaguar_pocket -c jaguar_pocket
#   tools/quartus.sh quartus_sta  projects/jaguar_pocket -c jaguar_pocket
#   # Milestone 0 — build upstream Jaguar_MiSTer unchanged:
#   tools/quartus.sh quartus_sh --flow compile refs/Jaguar_MiSTer/Jaguar_Single
set -euo pipefail

IMAGE="${QUARTUS_IMAGE:-raetro/quartus:21.1}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v docker >/dev/null; then
    cat >&2 <<'EOF'
error: docker not found.

Quartus cannot run natively on macOS. Install a Docker runtime first:

    brew install colima docker
    colima start --vm-type vz --rosetta --cpu 8 --memory 12 --disk 80

Then re-run this script. Alternatively, run the build in GitHub Actions on an
x86 runner (see docs/10-staged-plan.md).
EOF
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    cat >&2 <<'EOF'
error: the docker CLI is installed but no daemon is reachable.

If you use Colima:

    colima start --vm-type vz --rosetta --cpu 8 --memory 12 --disk 80
    colima status

Note the ~15 GB disk requirement for the extracted Quartus image.
EOF
    exit 1
fi

# Warn, do not block: macOS gets unstable when APFS runs out of headroom.
FREE_GB=$(df -g / 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "${FREE_GB:-}" ] && [ "$FREE_GB" -lt 25 ] 2>/dev/null; then
    echo "warning: only ${FREE_GB} GB free on /. The extracted Quartus image" >&2
    echo "         needs ~15 GB; consider the GitHub Actions route instead." >&2
fi

if [ "$#" -eq 0 ]; then
    echo "usage: tools/quartus.sh <quartus_command> [args...]" >&2
    exit 2
fi

exec docker run --rm -t \
    --platform linux/amd64 \
    -v "$REPO":/build \
    -w /build \
    "$IMAGE" "$@"
