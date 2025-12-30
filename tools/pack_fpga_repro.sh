#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/pack_fpga_repro.sh --dest <destination_dir> [--dest2 <path>] [--buildid <id>] [--dry-run]

Options:
  --dest <destination_dir>   Destination directory for tar.gz (alias for --dest1)
  --dest1 <path>             Archive destination directory for tar.gz
  --dest2 <path>             Delivery directory for redcomp.out tarballs
  --no-dest2                 Disable dest2 delivery
  --buildid <id>             Build ID (default: YYYYMMDD_HHMMSS_<host>_<user>)
  --dry-run                  Print files to collect without packaging
USAGE
}

log() {
  printf '[pack_fpga_repro] %s\n' "$*"
}

err() {
  printf '[pack_fpga_repro] ERROR: %s\n' "$*" >&2
}

need_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

DEST1_DIR=""
DEST2_DIR=""
BUILD_ID=""
DRY_RUN=false
DEST2_ENABLED=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      DEST1_DIR="$2"
      shift 2
      ;;
    --dest1)
      DEST1_DIR="$2"
      shift 2
      ;;
    --dest2)
      DEST2_DIR="$2"
      shift 2
      ;;
    --no-dest2)
      DEST2_ENABLED=false
      shift 1
      ;;
    --buildid)
      BUILD_ID="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$DEST1_DIR" ]]; then
  err "--dest or --dest1 is required"
  usage
  exit 1
fi

FPGA_ROOT="$(pwd)"
HOSTNAME="$(hostname -s)"
USER_NAME="$(id -un)"
TIME_NOW="$(date +%Y%m%d_%H%M%S)"

if [[ -z "$BUILD_ID" ]]; then
  BUILD_ID="${TIME_NOW}_${HOSTNAME}_${USER_NAME}"
fi

if ! need_cmd tar; then
  err "tar not found"
  exit 1
fi

if ! need_cmd gzip; then
  err "gzip not found"
  exit 1
fi

RSYNC_AVAILABLE=false
if need_cmd rsync; then
  RSYNC_AVAILABLE=true
else
  if ! cp --help 2>/dev/null | grep -q -- '--parents'; then
    err "Neither rsync nor cp --parents is available"
    exit 1
  fi
fi

GIT_AVAILABLE=true
if ! need_cmd git; then
  GIT_AVAILABLE=false
  log "git not found; will skip git metadata"
fi

if [[ -n "$DEST2_DIR" && "$DEST2_ENABLED" == false ]]; then
  err "--dest2 cannot be used together with --no-dest2"
  exit 1
fi

if [[ ! -d "$DEST1_DIR" ]]; then
  log "Creating DEST1 directory"
  mkdir -p "$DEST1_DIR"
fi

if [[ -n "$DEST2_DIR" && "$DEST2_ENABLED" == true && ! -d "$DEST2_DIR" ]]; then
  log "Creating dest2 directory"
  mkdir -p "$DEST2_DIR"
fi

WORK_DIR="$(mktemp -d)"
STAGING_ROOT="$WORK_DIR/repro_${BUILD_ID}"
META_DIR="$STAGING_ROOT/meta"
MISSING_FILE="$META_DIR/missing_files.txt"
MANIFEST_FILE="$META_DIR/manifest.txt"

cleanup() {
  if [[ -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

if [[ "$DRY_RUN" == true ]]; then
  trap cleanup EXIT
else
  trap cleanup EXIT
fi

mkdir -p "$META_DIR"

missing_items=()
collected_count=0
mb_dirs=()
mb_tag_dirs=()
third_step_symlink_count=0
third_step_copied_count=0

copy_relative() {
  local src="$1"
  local dest_root="$2"

  if [[ "$RSYNC_AVAILABLE" == true ]]; then
    (cd "$FPGA_ROOT" && rsync -a --relative "$src" "$dest_root/")
  else
    (cd "$FPGA_ROOT" && cp --parents -a "$src" "$dest_root/")
  fi
}

copy_into() {
  local src="$1"
  local dest_dir="$2"

  if [[ "$RSYNC_AVAILABLE" == true ]]; then
    (cd "$FPGA_ROOT" && rsync -a --relative "$src" "$dest_dir/")
  else
    (cd "$FPGA_ROOT" && cp --parents -a "$src" "$dest_dir/")
  fi
}

copy_with_links_and_relative() {
  local src="$1"
  local dest_root="$2"

  if [[ "$RSYNC_AVAILABLE" == true ]]; then
    (cd "$FPGA_ROOT" && rsync -aL --relative "$src" "$dest_root/")
  else
    (cd "$FPGA_ROOT" && cp -L -R --parents "$src" "$dest_root/")
  fi
}

process_third_step_item() {
  local rel_path="$1"
  local item_type="$2"
  local abs_path="$FPGA_ROOT/$rel_path"

  if [[ -L "$abs_path" ]]; then
    third_step_symlink_count=$((third_step_symlink_count + 1))
    if [[ ! -e "$abs_path" ]]; then
      missing_items+=("MISSING: $rel_path (broken symlink)")
      return
    fi
  fi

  if [[ "$item_type" == "file" ]]; then
    if [[ -f "$abs_path" ]]; then
      if [[ "$DRY_RUN" == true ]]; then
        print_collect "$rel_path"
      else
        copy_with_links_and_relative "$rel_path" "$STAGING_ROOT"
        collected_count=$((collected_count + 1))
        third_step_copied_count=$((third_step_copied_count + 1))
      fi
    else
      missing_items+=("MISSING: $rel_path")
    fi
  else
    if [[ -d "$abs_path" ]]; then
      if [[ "$DRY_RUN" == true ]]; then
        print_collect "$rel_path/"
      else
        copy_with_links_and_relative "$rel_path" "$STAGING_ROOT"
        collected_count=$((collected_count + 1))
        third_step_copied_count=$((third_step_copied_count + 1))
      fi
    else
      missing_items+=("MISSING: $rel_path")
    fi
  fi
}

print_collect() {
  printf '%s\n' "$1"
}

if [[ "$DRY_RUN" == true ]]; then
  log "Dry run: listing files to be collected"
fi

log "Step B: collect FPGA root inputs"
# Step B: FPGA root inputs
FPGA_INPUT_DIR="$STAGING_ROOT/fpga_root_inputs"
mkdir -p "$FPGA_INPUT_DIR"

mapfile -t input_files < <(find "$FPGA_ROOT" -maxdepth 1 -type f \( \
  -name '*.xdc' -o -name '*.tcl' -o -name '*.phd' -o -name '*.rdc' -o \
  -name '*.cfg' -o -name '*.v' -o -name '*.f' \) -printf '%f\n')

if [[ ${#input_files[@]} -eq 0 ]]; then
  log "No input files found at FPGA root"
else
  for f in "${input_files[@]}"; do
    if [[ "$DRY_RUN" == true ]]; then
      print_collect "fpga_root_inputs/$f"
    else
      copy_into "$f" "$FPGA_INPUT_DIR"
      collected_count=$((collected_count + 1))
    fi
  done
fi
log "Step B: done"

log "Step C: collect redcomp.out/rtlc/_red_veloce.log"
# Step C: redcomp.out/rtlc/_red_veloce.log
REDCOMP_RTLC_DIR="redcomp.out/rtlc/_red_veloce.log"
if [[ -d "$FPGA_ROOT/$REDCOMP_RTLC_DIR" ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    print_collect "$REDCOMP_RTLC_DIR/"
  else
    copy_relative "$REDCOMP_RTLC_DIR" "$STAGING_ROOT"
    collected_count=$((collected_count + 1))
  fi
else
  missing_items+=("MISSING: $REDCOMP_RTLC_DIR")
fi
log "Step C: done"

log "Step D: collect redcomp.out/spnr MB tag outputs (follow symlinks)"
# Step D: redcomp.out/spnr MB directories
SPNR_DIR="redcomp.out/spnr"
if [[ -d "$FPGA_ROOT/$SPNR_DIR" ]]; then
  shopt -s nullglob
  for mb_path in "$FPGA_ROOT/$SPNR_DIR"/MB*_*; do
    mb_name="$(basename "$mb_path")"
    mb_dirs+=("$mb_name")
    tag_dirs=("$mb_path"/tag_redfpga_*)
    if [[ ${#tag_dirs[@]} -eq 0 ]]; then
      missing_items+=("MISSING: $SPNR_DIR/$mb_name/tag_redfpga_* not found")
      continue
    fi
    tag_dir="${tag_dirs[0]}"
    tag_base="$(basename "$tag_dir")"
    mb_tag_dirs+=("$mb_name:$tag_base")

    rel_tag_dir="$SPNR_DIR/$mb_name/$tag_base"

    process_third_step_item "$rel_tag_dir/vivado.log" "file"
    process_third_step_item "$rel_tag_dir/vivado.jou" "file"
    process_third_step_item "$rel_tag_dir/post-route_reports" "dir"
  done
  shopt -u nullglob
else
  missing_items+=("MISSING: $SPNR_DIR not found")
fi
log "Step D: done"

log "Step E: capture environment and design snapshot"
# Step E: environment snapshot
if [[ "$DRY_RUN" == false ]]; then
  env | sort | while IFS= read -r line; do
    var="${line%%=*}"
    if [[ "$var" =~ (TOKEN|PASS|SECRET|KEY|CRED|COOKIE) ]]; then
      printf '%s=***REDACTED***\n' "$var"
    else
      printf '%s\n' "$line"
    fi
  done > "$META_DIR/env.txt"
fi

DESIGN_DIR=""
if [[ -n "${DESIGN_HOME:-}" && -d "${DESIGN_HOME}" ]]; then
  DESIGN_DIR="$DESIGN_HOME"
else
  while IFS='=' read -r var val; do
    if [[ -n "$val" && ("$val" == *"/design"* || "$val" == *"design_"* ) && -d "$val" ]]; then
      DESIGN_DIR="$val"
      break
    fi
  done < <(env)
fi

if [[ -z "$DESIGN_DIR" ]]; then
  missing_items+=("MISSING: DESIGN_DIR_NOT_FOUND")
else
  if [[ "$DRY_RUN" == true ]]; then
    print_collect "design_snapshot/$(basename "$DESIGN_DIR")/"
  else
    if [[ "$GIT_AVAILABLE" == true ]]; then
      (cd "$DESIGN_DIR" && git log -1 --pretty=oneline > "$META_DIR/design_git_head.txt")
      if [[ -s "$META_DIR/design_git_head.txt" ]]; then
        awk '{print $1}' "$META_DIR/design_git_head.txt" > "$META_DIR/design_commit_id.txt"
      fi
    else
      log "git not available; skipping design git metadata"
    fi
    mkdir -p "$STAGING_ROOT/design_snapshot"
    if [[ "$RSYNC_AVAILABLE" == true ]]; then
      rsync -a "$DESIGN_DIR"/ "$STAGING_ROOT/design_snapshot/$(basename "$DESIGN_DIR")/"
    else
      cp -a "$DESIGN_DIR" "$STAGING_ROOT/design_snapshot/"
    fi
    collected_count=$((collected_count + 1))
  fi
fi
log "Step E: done"

# Manifest and missing files
if [[ "$DRY_RUN" == false ]]; then
  {
    echo "BUILDID=$BUILD_ID"
    echo "TIME=$TIME_NOW"
    echo "HOST=$HOSTNAME"
    echo "USER=$USER_NAME"
    echo "FPGA_ROOT=$FPGA_ROOT"
    echo "DEST1=DEST1"
    echo "TAR_NAME=$TAR_NAME"
    echo "COLLECTED_COUNT=$collected_count"
    echo "THIRD_STEP_SYMLINK_COUNT=$third_step_symlink_count"
    echo "THIRD_STEP_COPIED_COUNT=$third_step_copied_count"
    echo "MB_DIRS=${mb_dirs[*]:-}"
    echo "MB_TAG_DIRS=${mb_tag_dirs[*]:-}"
    if [[ -n "$DESIGN_DIR" ]]; then
      echo "DESIGN_DIR=$DESIGN_DIR"
      if [[ -f "$META_DIR/design_commit_id.txt" ]]; then
        echo "DESIGN_COMMIT_ID=$(cat "$META_DIR/design_commit_id.txt")"
      fi
    else
      echo "DESIGN_DIR=DESIGN_DIR_NOT_FOUND"
    fi
  } > "$MANIFEST_FILE"

  if [[ ${#missing_items[@]} -gt 0 ]]; then
    printf '%s\n' "${missing_items[@]}" | tee "$MISSING_FILE" >> "$MANIFEST_FILE"
  fi
fi

TAR_NAME="fpga_repro_${BUILD_ID}.tar.gz"
TAR_PATH="$DEST1_DIR/$TAR_NAME"

if [[ "$DRY_RUN" == false ]]; then
  ( cd "$WORK_DIR" && tar -czf "$TAR_PATH" "repro_${BUILD_ID}" )
  log "Created tarball: DEST1/$TAR_NAME"
else
  log "Dry run: tarball creation skipped"
fi

if [[ -n "$DEST2_DIR" && "$DEST2_ENABLED" == true ]]; then
  log "Step F: deliver redcomp tarballs to dest2"
  dest2_errors_file="$META_DIR/dest2_errors.txt"
  dest2_results=()
  shopt -s nullglob
  redcomp_tarballs=("$FPGA_ROOT"/redcomp.out/*.tar.gz)
  shopt -u nullglob

  if [[ ${#redcomp_tarballs[@]} -eq 0 ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      log "No redcomp tarballs found for dest2"
    else
      echo "DEST2: no redcomp tarballs found" >> "$MANIFEST_FILE"
    fi
  else
    for tarball in "${redcomp_tarballs[@]}"; do
      tar_base="$(basename "$tarball")"
      tar_stem="${tar_base%.tar.gz}"
      dest2_tar="$DEST2_DIR/$tar_base"
      dest2_dir="$DEST2_DIR/$tar_stem"
      dest2_tmp="$DEST2_DIR/.tmp_${BUILD_ID}_${tar_stem}"

      if [[ "$DRY_RUN" == true ]]; then
        log "DEST2: copy $tar_base -> dest2, extract to $tar_stem/, remove tar.gz, chmod -R 777"
        continue
      fi

      cp -f "$tarball" "$dest2_tar"
      mkdir -p "$dest2_tmp"
      if ! tar -xzf "$dest2_tar" -C "$dest2_tmp"; then
        echo "DEST2: extract failed for $tar_base" >> "$dest2_errors_file"
        exit 1
      fi
      rm -f "$dest2_tar"
      mv "$dest2_tmp" "$dest2_dir"
      chmod -R 777 "$dest2_dir"

      dest2_results+=("$tar_base -> ${tar_stem}/ (chmod 777)")
    done
  fi

  if [[ "$DRY_RUN" == false ]]; then
    {
      echo "DEST2_DIR=$DEST2_DIR"
      if [[ ${#dest2_results[@]} -gt 0 ]]; then
        printf '%s\n' "DEST2_DELIVERED:"
        printf '%s\n' "${dest2_results[@]}"
      fi
    } >> "$MANIFEST_FILE"
  fi

  if [[ "$DRY_RUN" == false ]]; then
    dest2_readme="$DEST2_DIR/README_DEST2_LINK.txt"
    {
      echo "该目录为 FPGA server 投递区，与 DEST1 归档区对应（不暴露归档绝对路径）。"
      echo "BUILDID: $BUILD_ID"
      echo "TIME: $TIME_NOW"
      echo "HOST: $HOSTNAME"
      echo "USER: $USER_NAME"
      echo "Delivered tarballs:"
      if [[ ${#dest2_results[@]} -gt 0 ]]; then
        printf '%s\n' "${dest2_results[@]}" | sed 's/^/- /'
      else
        echo "- (none)"
      fi
      echo "Full repro package: $TAR_NAME (stored in DEST1)"
    } > "$dest2_readme"
  fi
  log "Step F: done"
fi
