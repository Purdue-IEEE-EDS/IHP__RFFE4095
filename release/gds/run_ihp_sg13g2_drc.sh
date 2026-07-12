#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./release/gds/run_ihp_sg13g2_drc.sh [gds_path] [top_cell] [host_report_dir]
#
# Environment overrides:
#   CONTAINER=3caa74e4d32c
#   MP=4
#   RUN_MODE=deep
#   FLATTEN=1       # 1 flattens TOP_CELL into a single cell for DRC input.
#                   # 0 keeps TOP_CELL hierarchy but removes unrelated tops.

CONTAINER="${CONTAINER:-3caa74e4d32c}"
GDS_PATH="${1:-/Users/eyn/IHP__RFFE4095/release/gds/RFFE4095.gds}"
TOP_CELL="${2:-RFFE4095}"
STAMP="$(date +%Y%m%d_%H%M%S)"
HOST_REPORT_DIR="${3:-$(dirname "$GDS_PATH")/drc_ihp_sg13g2_${TOP_CELL}_${STAMP}}"
MP="${MP:-4}"
RUN_MODE="${RUN_MODE:-deep}"
FLATTEN="${FLATTEN:-1}"

DRC_SCRIPT="/foss/pdks/ihp-sg13g2/libs.tech/klayout/tech/drc/run_drc.py"
CONTAINER_SOURCE_GDS="/tmp/$(basename "${GDS_PATH%.gds}")_${STAMP}_source.gds"
CONTAINER_DRC_GDS="/tmp/$(basename "${GDS_PATH%.gds}")_${STAMP}_${TOP_CELL}_drc_input.gds"
CONTAINER_RUN_DIR="/tmp/drc_ihp_sg13g2_${TOP_CELL}_${STAMP}"

if [[ ! -f "$GDS_PATH" ]]; then
  echo "ERROR: GDS not found: $GDS_PATH" >&2
  exit 2
fi

echo "Container: $CONTAINER"
echo "GDS:       $GDS_PATH"
echo "Top cell:  $TOP_CELL"
echo "Flatten:   $FLATTEN"
echo "Reports:   $HOST_REPORT_DIR"

docker exec -u root "$CONTAINER" test -f "$DRC_SCRIPT"
docker cp "$GDS_PATH" "${CONTAINER}:${CONTAINER_SOURCE_GDS}"

docker exec -u root \
  -e SOURCE_GDS="$CONTAINER_SOURCE_GDS" \
  -e DRC_GDS="$CONTAINER_DRC_GDS" \
  -e TOP_CELL="$TOP_CELL" \
  -e FLATTEN="$FLATTEN" \
  "$CONTAINER" bash -lc '
python3 - <<'"'"'PY'"'"'
import os
import sys
import pya

source_gds = os.environ["SOURCE_GDS"]
drc_gds = os.environ["DRC_GDS"]
top_cell = os.environ["TOP_CELL"]
flatten = os.environ.get("FLATTEN", "1").lower() in {"1", "true", "yes", "on"}

layout = pya.Layout()
layout.read(source_gds)
source_tops = [cell.name for cell in layout.top_cells()]
print(f"Source top cells: {source_tops}")

top = layout.cell(top_cell)
if top is None:
    print(f"ERROR: requested top cell {top_cell!r} not found as a cell", file=sys.stderr)
    sys.exit(3)

if top_cell not in source_tops:
    print(
        f"ERROR: requested cell {top_cell!r} exists, but is not a source top cell. "
        "This script only normalizes an existing top cell.",
        file=sys.stderr,
    )
    sys.exit(4)

other_tops = [cell for cell in layout.top_cells() if cell.name != top_cell]
if other_tops:
    layout.prune_cells(other_tops, -1)

top = layout.cell(top_cell)
if flatten:
    top.flatten(-1, True)

layout.write(drc_gds)

verify = pya.Layout()
verify.read(drc_gds)
verified_tops = [cell.name for cell in verify.top_cells()]
if verified_tops != [top_cell]:
    print(f"ERROR: normalized GDS should have exactly [{top_cell!r}], got {verified_tops}", file=sys.stderr)
    sys.exit(5)

verified_top = verify.cell(top_cell)
print(f"Normalized DRC GDS: {drc_gds}")
print(f"Normalized top cells: {verified_tops}")
print(f"Normalized cell count: {verify.cells()}")
print(f"{top_cell} child instances after normalization: {verified_top.child_instances()}")
PY
'

set +e
docker exec -u root \
  -e DRC_SCRIPT="$DRC_SCRIPT" \
  -e GDS_PATH="$CONTAINER_DRC_GDS" \
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
