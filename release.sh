#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./release.sh [source_gds] [top_cell=RFFE4095]
#
# If source_gds is omitted, the newest .gds under this repo is selected,
# excluding release/gds/RFFE4095.gds, release/v.* snapshots, build outputs,
# and stale DRC folders.
#
# Environment overrides:
#   CONTAINER=3caa74e4d32c
#   SOURCE_GDS=/path/to/input.gds
#   TOP_CELL=RFFE4095
#   FINAL_GDS=/path/to/release/gds/RFFE4095.gds
#   RUN_DRC=1          # Set to 0 to only refresh the final flattened GDS.
#   DRC_REPORT_ROOT=build/drc
#   MP=4
#   RUN_MODE=deep
#   FLATTEN=1
#   CLEAN_RELEASE_DRC=1
#   ALLOW_DRC_FAILURE=1
#   RELEASE_VERSION=v.1.0.1  # Optional; otherwise bumps the latest patch version.

usage() {
  sed -n '2,24p' "$0"
}

die() {
  echo "ERROR: $*" >&2
  exit 2
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

abs_path() {
  local path="$1"
  local dir
  local base

  if [[ -d "$path" ]]; then
    (cd "$path" && pwd -P)
    return
  fi

  dir="$(dirname "$path")"
  base="$(basename "$path")"
  (cd "$dir" && printf '%s/%s\n' "$(pwd -P)" "$base")
}

portable_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"
}

file_size() {
  stat -f %z "$1" 2>/dev/null || stat -c %s "$1"
}

relative_path() {
  local path="$1"
  case "$path" in
    "$REPO_ROOT"/*) printf '%s\n' "${path#$REPO_ROOT/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

latest_release_version() {
  local latest_major=-1
  local latest_minor=-1
  local latest_patch=-1
  local dir
  local base
  local major
  local minor
  local patch

  while IFS= read -r -d '' dir; do
    base="$(basename "$dir")"
    if [[ "$base" =~ ^v\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
      major="${BASH_REMATCH[1]}"
      minor="${BASH_REMATCH[2]}"
      patch="${BASH_REMATCH[3]}"
      if (( major > latest_major || \
            (major == latest_major && minor > latest_minor) || \
            (major == latest_major && minor == latest_minor && patch > latest_patch) )); then
        latest_major="$major"
        latest_minor="$minor"
        latest_patch="$patch"
      fi
    fi
  done < <(find "$RELEASE_DIR" -maxdepth 1 -type d -name 'v.*' -print0)

  if (( latest_major < 0 )); then
    printf 'v.0.0.0\n'
  else
    printf 'v.%d.%d.%d\n' "$latest_major" "$latest_minor" "$latest_patch"
  fi
}

next_release_version() {
  local requested="${RELEASE_VERSION:-}"
  local latest
  local major
  local minor
  local patch

  if [[ -n "$requested" ]]; then
    [[ "$requested" =~ ^v\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
      die "RELEASE_VERSION must look like v.1.2.3, got: $requested"
    printf '%s\n' "$requested"
    return
  fi

  latest="$(latest_release_version)"
  if [[ "$latest" == "v.0.0.0" ]]; then
    printf 'v.1.0.0\n'
    return
  fi

  IFS=. read -r _ major minor patch <<< "$latest"
  printf 'v.%d.%d.%d\n' "$major" "$minor" "$((patch + 1))"
}

extract_meta_value() {
  local key="$1"
  local meta_file="$2"
  sed -n "s/^${key}=//p" "$meta_file" | tail -n 1
}

write_release_note() {
  local version="$1"
  local note_path="$2"
  local version_gds="$3"
  local bytes="$4"
  local fingerprint="$5"
  local structures="$6"
  local direct_child_refs="$7"
  local release_date
  local source_rel
  local gds_rel

  release_date="$(date +%F)"
  source_rel="$(relative_path "$SOURCE_GDS")"
  gds_rel="$(relative_path "$version_gds")"

  cat > "$note_path" <<EOF
# RFFE4095 Release $version

## Release Date
$release_date

## Contents

- **GDS**: \`gds/$(basename "$version_gds")\`

## Source

- source GDS: \`$source_rel\`
- top cell: \`$TOP_CELL\`
- flattened: \`$FLATTEN\`

\`\`\`
file: $gds_rel
bytes: $bytes
structures: $structures
top cells: ['$TOP_CELL']
$TOP_CELL reachable cells: $structures
$TOP_CELL direct child refs: $direct_child_refs
geometry fingerprint: $fingerprint
\`\`\`
EOF
}

ensure_latest_release_snapshot() {
  local latest
  local version_dir
  local version_gds_dir
  local version_gds
  local version_note

  latest="$(latest_release_version)"
  [[ "$latest" != "v.0.0.0" ]] || return 0

  version_dir="$RELEASE_DIR/$latest"
  version_gds_dir="$version_dir/gds"
  version_gds="$version_gds_dir/$(basename "$FINAL_GDS")"
  version_note="$version_dir/ReleaseNote.md"

  [[ -f "$version_gds" ]] && return 0
  [[ -f "$FINAL_GDS" ]] || return 0

  mkdir -p "$version_gds_dir"
  cp "$FINAL_GDS" "$version_gds"

  if [[ ! -f "$version_note" ]]; then
    write_release_note \
      "$latest" \
      "$version_note" \
      "$version_gds" \
      "$(file_size "$version_gds")" \
      "$RELEASE_FINGERPRINT" \
      "$RELEASE_STRUCTURES" \
      "$RELEASE_DIRECT_CHILD_REFS"
  fi

  echo "Backfilled release snapshot: $(relative_path "$version_gds")"
}

newest_release_gds() {
  local newest=""
  local newest_mtime=-1
  local candidate
  local candidate_abs
  local candidate_mtime

  while IFS= read -r -d '' candidate; do
    candidate_abs="$(abs_path "$candidate")"

    if [[ "$candidate_abs" == "$FINAL_GDS" ]]; then
      continue
    fi

    case "$candidate_abs" in
      "$REPO_ROOT/.git/"*|"$REPO_ROOT/build/"*|"$RELEASE_DIR"/v.*/*|"$RELEASE_GDS_DIR"/drc_*/*)
        continue
        ;;
    esac

    candidate_mtime="$(portable_mtime "$candidate_abs")"
    if (( candidate_mtime > newest_mtime )); then
      newest="$candidate_abs"
      newest_mtime="$candidate_mtime"
    fi
  done < <(
    find "$REPO_ROOT" \
      \( -path "$REPO_ROOT/.git" -o -path "$REPO_ROOT/build" -o -path "$RELEASE_DIR/v.*" -o -path "$RELEASE_GDS_DIR/drc_*" \) -prune \
      -o -type f -name '*.gds' -print0
  )

  [[ -n "$newest" ]] || return 1
  printf '%s\n' "$newest"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$SCRIPT_DIR"
RELEASE_DIR="${RELEASE_DIR:-$REPO_ROOT/release}"
RELEASE_GDS_DIR="${RELEASE_GDS_DIR:-$RELEASE_DIR/gds}"
FINAL_GDS="${FINAL_GDS:-$RELEASE_GDS_DIR/RFFE4095.gds}"
SOURCE_GDS="${1:-${SOURCE_GDS:-}}"
TOP_CELL="${2:-${TOP_CELL:-RFFE4095}}"

CONTAINER="${CONTAINER:-3caa74e4d32c}"
MP="${MP:-4}"
RUN_MODE="${RUN_MODE:-deep}"
FLATTEN="${FLATTEN:-1}"
RUN_DRC="${RUN_DRC:-1}"
CLEAN_RELEASE_DRC="${CLEAN_RELEASE_DRC:-1}"
ALLOW_DRC_FAILURE="${ALLOW_DRC_FAILURE:-1}"
DRC_REPORT_ROOT="${DRC_REPORT_ROOT:-$REPO_ROOT/build/drc}"
DRC_SCRIPT="/foss/pdks/ihp-sg13g2/libs.tech/klayout/tech/drc/run_drc.py"

mkdir -p "$RELEASE_GDS_DIR"

REPO_ROOT="$(abs_path "$REPO_ROOT")"
RELEASE_DIR="$(abs_path "$RELEASE_DIR")"
RELEASE_GDS_DIR="$(abs_path "$RELEASE_GDS_DIR")"
FINAL_GDS="$(abs_path "$FINAL_GDS")"

if is_truthy "$CLEAN_RELEASE_DRC"; then
  while IFS= read -r -d '' stale_drc_dir; do
    echo "Removing stale DRC report from release dir: ${stale_drc_dir#$REPO_ROOT/}"
    rm -rf "$stale_drc_dir"
  done < <(find "$RELEASE_GDS_DIR" -maxdepth 1 -type d -name 'drc_*' -print0)
fi

if [[ -z "$SOURCE_GDS" ]]; then
  SOURCE_GDS="$(newest_release_gds)" || die "No source .gds found under $REPO_ROOT"
else
  SOURCE_GDS="$(abs_path "$SOURCE_GDS")"
fi

[[ -f "$SOURCE_GDS" ]] || die "GDS not found: $SOURCE_GDS"

if is_truthy "$RUN_DRC"; then
  mkdir -p "$DRC_REPORT_ROOT"
  DRC_REPORT_ROOT="$(abs_path "$DRC_REPORT_ROOT")"
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
HOST_FINAL_TMP="$RELEASE_GDS_DIR/.${TOP_CELL}_${STAMP}_release.gds.tmp"
HOST_REPORT_DIR="$DRC_REPORT_ROOT/drc_ihp_sg13g2_${TOP_CELL}_${STAMP}"
CONTAINER_SOURCE_GDS="/tmp/${TOP_CELL}_${STAMP}_source.gds"
CONTAINER_RELEASE_GDS="/tmp/${TOP_CELL}_${STAMP}_release_flat.gds"
CONTAINER_RUN_DIR="/tmp/drc_ihp_sg13g2_${TOP_CELL}_${STAMP}"
CONTAINER_RELEASE_META="/tmp/${TOP_CELL}_${STAMP}_release_meta.env"
CONTAINER_PREVIOUS_FINAL_GDS="/tmp/${TOP_CELL}_${STAMP}_previous_final.gds"
CONTAINER_PREVIOUS_META="/tmp/${TOP_CELL}_${STAMP}_previous_meta.env"
HOST_RELEASE_META="$RELEASE_GDS_DIR/.${TOP_CELL}_${STAMP}_release_meta.env.tmp"
HOST_PREVIOUS_META="$RELEASE_GDS_DIR/.${TOP_CELL}_${STAMP}_previous_meta.env.tmp"

cleanup() {
  rm -f "$HOST_FINAL_TMP"
  docker exec -u root "$CONTAINER" rm -rf \
    "$CONTAINER_SOURCE_GDS" \
    "$CONTAINER_RELEASE_GDS" \
    "$CONTAINER_RELEASE_META" \
    "$CONTAINER_PREVIOUS_FINAL_GDS" \
    "$CONTAINER_PREVIOUS_META" \
    "$CONTAINER_RUN_DIR" >/dev/null 2>&1 || true
  rm -f "$HOST_RELEASE_META" "$HOST_PREVIOUS_META"
}
trap cleanup EXIT

echo "Container:      $CONTAINER"
echo "Source GDS:     $SOURCE_GDS"
echo "Final GDS:      $FINAL_GDS"
echo "Top cell:       $TOP_CELL"
echo "Flatten:        $FLATTEN"
echo "Run DRC:        $RUN_DRC"
echo "Allow DRC fail: $ALLOW_DRC_FAILURE"
if is_truthy "$RUN_DRC"; then
  echo "DRC reports:    $HOST_REPORT_DIR"
fi

if is_truthy "$RUN_DRC"; then
  docker exec -u root "$CONTAINER" test -f "$DRC_SCRIPT"
fi
docker cp "$SOURCE_GDS" "${CONTAINER}:${CONTAINER_SOURCE_GDS}"

docker exec -u root \
  -e SOURCE_GDS="$CONTAINER_SOURCE_GDS" \
  -e RELEASE_GDS="$CONTAINER_RELEASE_GDS" \
  -e RELEASE_META="$CONTAINER_RELEASE_META" \
  -e TOP_CELL="$TOP_CELL" \
  -e FLATTEN="$FLATTEN" \
  "$CONTAINER" bash -lc '
python3 - <<'"'"'PY'"'"'
import os
import sys
import hashlib
import pya

source_gds = os.environ["SOURCE_GDS"]
release_gds = os.environ["RELEASE_GDS"]
release_meta = os.environ.get("RELEASE_META")
top_cell = os.environ["TOP_CELL"]
flatten = os.environ.get("FLATTEN", "1").lower() in {"1", "true", "yes", "on"}

def layer_key(layout, layer_index):
    info = layout.get_info(layer_index)
    return (info.layer, info.datatype, info.name or "")

def layout_fingerprint(layout):
    digest = hashlib.sha256()
    layers = sorted(layout.layer_indices(), key=lambda layer_index: layer_key(layout, layer_index))
    cells = sorted(layout.each_cell(), key=lambda cell: cell.name)

    for cell in cells:
        digest.update(f"cell:{cell.name}\n".encode())

        instances = sorted(str(inst) for inst in cell.each_inst())
        for inst in instances:
            digest.update(f"inst:{inst}\n".encode())

        for layer_index in layers:
            info = layout.get_info(layer_index)
            shapes = sorted(str(shape) for shape in cell.shapes(layer_index).each())
            if not shapes:
                continue
            layer_name = info.name or ""
            digest.update(f"layer:{info.layer}/{info.datatype}/{layer_name}\n".encode())
            for shape in shapes:
                digest.update(f"shape:{shape}\n".encode())

    return digest.hexdigest()

layout = pya.Layout()
layout.read(source_gds)
source_tops = [cell.name for cell in layout.top_cells()]
source_top_preview = source_tops[:20]
source_top_suffix = " ..." if len(source_tops) > len(source_top_preview) else ""
print(f"Source top cell count: {len(source_tops)}")
print(f"Source top cell preview: {source_top_preview}{source_top_suffix}")

top = layout.cell(top_cell)
if top is None:
    print(f"ERROR: requested top cell {top_cell!r} not found as a cell", file=sys.stderr)
    sys.exit(3)

if top_cell not in source_tops:
    print(
        f"ERROR: requested cell {top_cell!r} exists, but is not a source top cell. "
        "Release normalization only accepts an existing source top cell.",
        file=sys.stderr,
    )
    sys.exit(4)

other_tops = [cell for cell in layout.top_cells() if cell.name != top_cell]
if other_tops:
    layout.prune_cells(other_tops, -1)

top = layout.cell(top_cell)
if flatten:
    top.flatten(-1, True)

layout.write(release_gds)

verify = pya.Layout()
verify.read(release_gds)
verified_tops = [cell.name for cell in verify.top_cells()]
if verified_tops != [top_cell]:
    print(f"ERROR: release GDS should have exactly [{top_cell!r}], got {verified_tops}", file=sys.stderr)
    sys.exit(5)

verified_top = verify.cell(top_cell)
if flatten and verified_top.child_instances() != 0:
    print(
        f"ERROR: flattened release top still has {verified_top.child_instances()} child instances",
        file=sys.stderr,
    )
    sys.exit(6)

print(f"Normalized release GDS: {release_gds}")
print(f"Release top cells: {verified_tops}")
print(f"Release cell count: {verify.cells()}")
print(f"{top_cell} child instances after normalization: {verified_top.child_instances()}")

if release_meta:
    with open(release_meta, "w", encoding="utf-8") as meta:
        meta.write(f"FINGERPRINT={layout_fingerprint(verify)}\n")
        meta.write(f"STRUCTURES={verify.cells()}\n")
        meta.write(f"DIRECT_CHILD_REFS={verified_top.child_instances()}\n")
PY
'

docker cp "${CONTAINER}:${CONTAINER_RELEASE_GDS}" "$HOST_FINAL_TMP"
docker cp "${CONTAINER}:${CONTAINER_RELEASE_META}" "$HOST_RELEASE_META"

RELEASE_FINGERPRINT="$(extract_meta_value FINGERPRINT "$HOST_RELEASE_META")"
RELEASE_STRUCTURES="$(extract_meta_value STRUCTURES "$HOST_RELEASE_META")"
RELEASE_DIRECT_CHILD_REFS="$(extract_meta_value DIRECT_CHILD_REFS "$HOST_RELEASE_META")"
PREVIOUS_FINGERPRINT=""
GDS_CHANGED=1
FINAL_UPDATED=0

if [[ -f "$FINAL_GDS" ]]; then
  docker cp "$FINAL_GDS" "${CONTAINER}:${CONTAINER_PREVIOUS_FINAL_GDS}"
  set +e
  docker exec -u root \
    -e GDS_PATH="$CONTAINER_PREVIOUS_FINAL_GDS" \
    -e META_PATH="$CONTAINER_PREVIOUS_META" \
    -e TOP_CELL="$TOP_CELL" \
    "$CONTAINER" bash -lc '
python3 - <<'"'"'PY'"'"'
import os
import sys
import hashlib
import pya

gds_path = os.environ["GDS_PATH"]
meta_path = os.environ["META_PATH"]
top_cell = os.environ["TOP_CELL"]

def layer_key(layout, layer_index):
    info = layout.get_info(layer_index)
    return (info.layer, info.datatype, info.name or "")

def layout_fingerprint(layout):
    digest = hashlib.sha256()
    layers = sorted(layout.layer_indices(), key=lambda layer_index: layer_key(layout, layer_index))
    cells = sorted(layout.each_cell(), key=lambda cell: cell.name)

    for cell in cells:
        digest.update(f"cell:{cell.name}\n".encode())

        instances = sorted(str(inst) for inst in cell.each_inst())
        for inst in instances:
            digest.update(f"inst:{inst}\n".encode())

        for layer_index in layers:
            info = layout.get_info(layer_index)
            shapes = sorted(str(shape) for shape in cell.shapes(layer_index).each())
            if not shapes:
                continue
            layer_name = info.name or ""
            digest.update(f"layer:{info.layer}/{info.datatype}/{layer_name}\n".encode())
            for shape in shapes:
                digest.update(f"shape:{shape}\n".encode())

    return digest.hexdigest()

layout = pya.Layout()
layout.read(gds_path)
if layout.cell(top_cell) is None:
    print(f"ERROR: previous final GDS has no {top_cell!r} cell", file=sys.stderr)
    sys.exit(7)

with open(meta_path, "w", encoding="utf-8") as meta:
    meta.write(f"FINGERPRINT={layout_fingerprint(layout)}\n")
PY
'
  PREVIOUS_META_STATUS=$?
  set -e

  if [[ "$PREVIOUS_META_STATUS" -eq 0 ]]; then
    docker cp "${CONTAINER}:${CONTAINER_PREVIOUS_META}" "$HOST_PREVIOUS_META"
    PREVIOUS_FINGERPRINT="$(extract_meta_value FINGERPRINT "$HOST_PREVIOUS_META")"
  else
    echo "WARNING: previous final GDS could not be fingerprinted; treating candidate as a new release." >&2
  fi
fi

if [[ -n "$PREVIOUS_FINGERPRINT" && "$PREVIOUS_FINGERPRINT" == "$RELEASE_FINGERPRINT" ]]; then
  GDS_CHANGED=0
fi

if [[ "$GDS_CHANGED" -eq 1 ]]; then
  NEW_VERSION="$(next_release_version)"
  VERSION_DIR="$RELEASE_DIR/$NEW_VERSION"
  VERSION_GDS_DIR="$VERSION_DIR/gds"
  VERSION_GDS="$VERSION_GDS_DIR/$(basename "$FINAL_GDS")"
  VERSION_NOTE="$VERSION_DIR/ReleaseNote.md"

  [[ ! -e "$VERSION_DIR" ]] || die "Release version already exists: $VERSION_DIR"

  mkdir -p "$VERSION_GDS_DIR"
  cp "$HOST_FINAL_TMP" "$VERSION_GDS"
  write_release_note \
    "$NEW_VERSION" \
    "$VERSION_NOTE" \
    "$VERSION_GDS" \
    "$(file_size "$VERSION_GDS")" \
    "$RELEASE_FINGERPRINT" \
    "$RELEASE_STRUCTURES" \
    "$RELEASE_DIRECT_CHILD_REFS"

  mv "$HOST_FINAL_TMP" "$FINAL_GDS"
  FINAL_UPDATED=1

  echo
  echo "Created release version: $VERSION_DIR"
else
  rm -f "$HOST_FINAL_TMP"

  echo
  echo "No GDS geometry change detected; release version unchanged."
fi

ensure_latest_release_snapshot

echo
if [[ "$FINAL_UPDATED" -eq 1 ]]; then
  echo "Updated final release GDS: $FINAL_GDS"
else
  echo "Final release GDS already matched: $FINAL_GDS"
fi

if ! is_truthy "$RUN_DRC"; then
  echo "DRC skipped because RUN_DRC=$RUN_DRC"
  exit 0
fi

set +e
docker exec -u root \
  -e DRC_SCRIPT="$DRC_SCRIPT" \
  -e GDS_PATH="$CONTAINER_RELEASE_GDS" \
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

if docker exec -u root "$CONTAINER" test -d "$CONTAINER_RUN_DIR"; then
  mkdir -p "$DRC_REPORT_ROOT"
  docker cp "${CONTAINER}:${CONTAINER_RUN_DIR}" "$HOST_REPORT_DIR"
  echo "Reports copied to: $HOST_REPORT_DIR"
else
  echo "WARNING: DRC run directory was not produced: $CONTAINER_RUN_DIR" >&2
fi

echo
echo "DRC exit status: $DRC_STATUS"
echo "Final release GDS remains: $FINAL_GDS"
echo "Open the *_full.lyrdb file in KLayout to inspect markers."

if [[ "$DRC_STATUS" -ne 0 ]] && is_truthy "$ALLOW_DRC_FAILURE"; then
  echo "DRC failed, but release is kept because ALLOW_DRC_FAILURE=$ALLOW_DRC_FAILURE."
  exit 0
fi

exit "$DRC_STATUS"
