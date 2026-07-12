#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./release/gds/run_ihp_sg13g2_drc.sh [gds_path] [top_cell] [host_report_dir]
#
# Environment overrides:
#   CONTAINER=3caa74e4d32c
#   MP=4
#   RUN_MODE=deep

CONTAINER="${CONTAINER:-3caa74e4d32c}"
GDS_PATH="${1:-/Users/eyn/IHP__RFFE4095/release/gds/RFFE4095.gds}"
TOP_CELL="${2:-RFFE4095}"
STAMP="$(date +%Y%m%d_%H%M%S)"
HOST_REPORT_DIR="${3:-$(dirname "$GDS_PATH")/drc_ihp_sg13g2_${TOP_CELL}_${STAMP}}"
MP="${MP:-4}"
RUN_MODE="${RUN_MODE:-deep}"

DRC_SCRIPT="/foss/pdks/ihp-sg13g2/libs.tech/klayout/tech/drc/run_drc.py"
CONTAINER_GDS="/tmp/$(basename "${GDS_PATH%.gds}")_${STAMP}_drc_input.gds"
CONTAINER_RUN_DIR="/tmp/drc_ihp_sg13g2_${TOP_CELL}_${STAMP}"

if [[ ! -f "$GDS_PATH" ]]; then
  echo "ERROR: GDS not found: $GDS_PATH" >&2
  exit 2
fi

echo "Container: $CONTAINER"
echo "GDS:       $GDS_PATH"
echo "Top cell:  $TOP_CELL"
echo "Reports:   $HOST_REPORT_DIR"

docker exec -u root "$CONTAINER" test -f "$DRC_SCRIPT"
docker cp "$GDS_PATH" "${CONTAINER}:${CONTAINER_GDS}"

docker exec -u root \
  -e GDS_PATH="$CONTAINER_GDS" \
  -e TOP_CELL="$TOP_CELL" \
  "$CONTAINER" bash -lc '
python3 - <<'"'"'PY'"'"'
import os
import sys
import pya

gds_path = os.environ["GDS_PATH"]
top_cell = os.environ["TOP_CELL"]

layout = pya.Layout()
layout.read(gds_path)
tops = [cell.name for cell in layout.top_cells()]
print(f"Detected top cells: {tops}")

if top_cell not in tops:
    print(f"ERROR: requested top cell {top_cell!r} not found", file=sys.stderr)
    sys.exit(3)
PY
'

set +e
docker exec -u root \
  -e DRC_SCRIPT="$DRC_SCRIPT" \
  -e GDS_PATH="$CONTAINER_GDS" \
  -e TOP_CELL="$TOP_CELL" \
  -e RUN_MODE="$RUN_MODE" \
  -e MP="$MP" \
  -e RUN_DIR="$CONTAINER_RUN_DIR" \
  "$CONTAINER" bash -lc '
python3 "$DRC_SCRIPT" \
  --path="$GDS_PATH" \
  --topcell="$TOP_CELL" \
  --run_mode="$RUN_MODE" \
  --mp="$MP" \
  --run_dir="$RUN_DIR"
'
DRC_STATUS=$?
set -e

mkdir -p "$(dirname "$HOST_REPORT_DIR")"
docker cp "${CONTAINER}:${CONTAINER_RUN_DIR}" "$HOST_REPORT_DIR"

echo
echo "DRC exit status: $DRC_STATUS"
echo "Reports copied to: $HOST_REPORT_DIR"
echo "Open the *_full.lyrdb file in KLayout to inspect markers."

exit "$DRC_STATUS"
