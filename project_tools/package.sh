#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [NAME] [OUT_DIR]
  $(basename "$0") [--name NAME] [--out-dir DIR] [--format tar|tar.gz|zip|tar.zst]
                   [--exclude-from FILE]... [--no-default-excludes]
                   [--source-only] [--split-size SIZE] [--keep-archive]
                   [--work-dir DIR] [--progress]

Options:
  --name NAME            Archive base name (default: project directory name)
  --out-dir DIR          Output directory (default: parent of project root)
  --format FORMAT        Archive format: tar | tar.gz | zip | tar.zst (default: tar)
  --exclude-from FILE    Read additional exclude patterns from FILE; can be repeated
  --no-default-excludes  Disable built-in exclude patterns
  --source-only          Exclude runtime data directories for a source-only archive
  --exclude-runtime      Alias for --source-only
  --split-size SIZE      Split archive into SIZE chunks (for example: 950m, 1g)
  --keep-archive         Keep the full archive alongside split parts
  --work-dir DIR         Temporary work directory base (default: OUT_DIR)
  --progress             Show command progress while creating the archive
  -h, --help             Show this help

Environment:
  PACKAGE_REPO_TMPDIR    Temporary work directory base when --work-dir is omitted

Positional compatibility:
  NAME and OUT_DIR are still accepted as the first two positional arguments.
EOF
}

require_value() {
  local option="$1"
  local value="${2-}"

  [[ -n "$value" && "$value" != -* ]] || die "Missing value for ${option}"
}

resolve_path_arg() {
  local raw_path="$1"

  if [[ "$raw_path" == /* ]]; then
    printf '%s\n' "$raw_path"
  else
    printf '%s/%s\n' "$CALLER_PWD" "$raw_path"
  fi
}

load_exclude_file() {
  local exclude_file="$1"
  local line

  [[ -f "$exclude_file" ]] || die "Exclude file not found: $exclude_file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    EXCLUDES+=("$line")
  done <"$exclude_file"
}

checksum_file() {
  local archive_path="$1"
  local checksum_path="${2:-${archive_path}.sha256}"
  local archive_dir
  local archive_name
  local checksum_name

  archive_dir="$(cd "$(dirname "$archive_path")" && pwd)"
  archive_name="$(basename "$archive_path")"
  checksum_name="$(basename "$checksum_path")"

  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$archive_dir" && sha256sum "$archive_name" >"$checksum_name")
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$archive_dir" && shasum -a 256 "$archive_name" >"$checksum_name")
  else
    die "No SHA-256 checksum tool found (need sha256sum or shasum)"
  fi
}

file_size_bytes() {
  local file_path="$1"
  wc -c <"$file_path" | tr -d '[:space:]'
}

parse_size_to_bytes() {
  local raw_size="$1"
  local normalized
  local number
  local unit
  local factor

  normalized="${raw_size,,}"
  [[ "$normalized" =~ ^([0-9]+)([a-z]*)$ ]] || die "Invalid split size: $raw_size"

  number="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"

  case "$unit" in
  "" | b) factor=1 ;;
  k | kb | kib) factor=$((1024)) ;;
  m | mb | mib) factor=$((1024 * 1024)) ;;
  g | gb | gib) factor=$((1024 * 1024 * 1024)) ;;
  t | tb | tib) factor=$((1024 * 1024 * 1024 * 1024)) ;;
  *) die "Unsupported split size suffix: $raw_size" ;;
  esac

  ((number > 0)) || die "Split size must be greater than zero"
  printf '%s\n' "$((number * factor))"
}

has_glob() {
  local pattern="$1"
  [[ "$pattern" == *'*'* || "$pattern" == *'?'* || "$pattern" == *'['* ]]
}

build_zip_exclude_args() {
  local pattern normalized

  ZIP_EXCLUDE_ARGS=()
  for pattern in "${EXCLUDES[@]}"; do
    normalized="${pattern%/}"
    [[ -n "$normalized" ]] || normalized="$pattern"

    ZIP_EXCLUDE_ARGS+=(-x "$normalized")

    if ! has_glob "$normalized"; then
      ZIP_EXCLUDE_ARGS+=(-x "$normalized/*")

      if [[ "$normalized" != */* ]]; then
        ZIP_EXCLUDE_ARGS+=(-x "*/$normalized")
        ZIP_EXCLUDE_ARGS+=(-x "*/$normalized/*")
      fi
    fi
  done
}

verify_zip_archive() {
  local archive_path="$1"

  if command -v unzip >/dev/null 2>&1; then
    unzip -tq "$archive_path" >/dev/null
  elif command -v 7z >/dev/null 2>&1; then
    7z t "$archive_path" >/dev/null
  elif command -v zip >/dev/null 2>&1; then
    zip -T "$archive_path" >/dev/null
  else
    die "Created ZIP archive but could not verify it (need unzip, 7z, or zip -T)"
  fi
}

tar_supports_zstd() {
  tar --help 2>/dev/null | grep -q -- '--zstd'
}

split_archive() {
  local archive_path="$1"
  local part_prefix="$2"
  local split_candidates=()

  command -v split >/dev/null 2>&1 || die "split not found"
  [[ -n "$SPLIT_SIZE_BYTES" ]] || die "Internal error: split size bytes not set"

  if [[ "$PROGRESS" == true ]]; then
    echo "Splitting $(basename "$archive_path") into ${SPLIT_SIZE} parts ..."
  fi

  split -d -a 4 -b "$SPLIT_SIZE_BYTES" "$archive_path" "$part_prefix"

  shopt -s nullglob
  split_candidates=("${part_prefix}"*)
  shopt -u nullglob

  [[ ${#split_candidates[@]} -gt 0 ]] || die "Failed to create split parts for $(basename "$archive_path")"
  SPLIT_PARTS=("${split_candidates[@]}")
}

write_split_manifest() {
  local archive_path="$1"
  shift
  local manifest_path="${archive_path}.parts.txt"
  local archive_name
  local part_path

  archive_name="$(basename "$archive_path")"

  {
    echo "Archive: ${archive_name}"
    echo "Split size: ${SPLIT_SIZE}"
    echo "Split size bytes: ${SPLIT_SIZE_BYTES}"
    echo
    echo "Parts:"
    for part_path in "$@"; do
      echo "  $(basename "$part_path")"
    done
    echo
    echo "Reassemble:"
    echo "  cat ${archive_name}.part-* > ${archive_name}"
    echo
    echo "Verify:"
    echo "  Use ${archive_name}.sha256 to verify the reassembled archive."
    echo "  Each part also has its own .sha256 file."
  } >"$manifest_path"
}

run_cmd() {
  if [[ "$PROGRESS" == true ]]; then
    "$@"
  else
    "$@" >/dev/null
  fi
}

create_tar() {
  local archive_path="$1"
  local tar_args
  local pattern

  command -v tar >/dev/null 2>&1 || die "tar not found"

  tar_args=(-cf "$archive_path")
  for pattern in "${EXCLUDES[@]}"; do
    tar_args+=(--exclude "$pattern")
  done
  tar_args+=(.)

  if [[ "$PROGRESS" == true ]]; then
    tar "${tar_args[@]/-cf/-cvf}"
  else
    tar "${tar_args[@]}"
  fi
  tar -tf "$archive_path" >/dev/null
}

create_tar_gz() {
  local archive_path="$1"
  local tar_args
  local tar_stream_args
  local pattern

  command -v tar >/dev/null 2>&1 || die "tar not found"

  tar_args=(-czf "$archive_path")
  for pattern in "${EXCLUDES[@]}"; do
    tar_args+=(--exclude "$pattern")
  done
  tar_args+=(.)

  if [[ "$PROGRESS" == true ]]; then
    if command -v pv >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1; then
      tar_stream_args=(-cf -)
      for pattern in "${EXCLUDES[@]}"; do
        tar_stream_args+=(--exclude "$pattern")
      done
      tar_stream_args+=(.)
      tar "${tar_stream_args[@]}" | pv | gzip >"$archive_path"
    else
      tar "${tar_args[@]/-czf/-czvf}"
    fi
  else
    tar "${tar_args[@]}"
  fi
  tar -tzf "$archive_path" >/dev/null
}

create_zip() {
  local archive_path="$1"
  local zip_args
  local seven_z_args
  local pattern

  if command -v zip >/dev/null 2>&1; then
    zip_args=(-r -9 "$archive_path" .)
    build_zip_exclude_args
    run_cmd zip "${zip_args[@]}" "${ZIP_EXCLUDE_ARGS[@]}"
    verify_zip_archive "$archive_path"
    return
  fi

  if command -v 7z >/dev/null 2>&1; then
    seven_z_args=(a -tzip -mx=9 "$archive_path" .)
    for pattern in "${EXCLUDES[@]}"; do
      seven_z_args+=("-xr!${pattern}")
    done
    run_cmd 7z "${seven_z_args[@]}"
    7z t "$archive_path" >/dev/null
    return
  fi

  die "Neither zip nor 7z is installed"
}

create_tar_zst() {
  local archive_path="$1"
  local tar_args
  local tar_stream_args
  local pattern

  command -v tar >/dev/null 2>&1 || die "tar not found"

  if [[ "$PROGRESS" == true ]] && command -v pv >/dev/null 2>&1 && command -v zstd >/dev/null 2>&1; then
    tar_stream_args=(-cf -)
    for pattern in "${EXCLUDES[@]}"; do
      tar_stream_args+=(--exclude "$pattern")
    done
    tar_stream_args+=(.)

    tar "${tar_stream_args[@]}" | pv | zstd -q -o "$archive_path"
    zstd -dc "$archive_path" | tar -tf - >/dev/null
    return
  fi

  if tar_supports_zstd; then
    tar_args=(--zstd -cf "$archive_path")
    for pattern in "${EXCLUDES[@]}"; do
      tar_args+=(--exclude "$pattern")
    done
    tar_args+=(.)

    if [[ "$PROGRESS" == true ]]; then
      tar "${tar_args[@]/-cf/-cvf}"
    else
      tar "${tar_args[@]}"
    fi
    tar --zstd -tf "$archive_path" >/dev/null
    return
  fi

  if command -v zstd >/dev/null 2>&1; then
    tar_args=(-cf -)
    for pattern in "${EXCLUDES[@]}"; do
      tar_args+=(--exclude "$pattern")
    done
    tar_args+=(.)

    if [[ "$PROGRESS" == true ]] && command -v pv >/dev/null 2>&1; then
      tar "${tar_args[@]}" | pv | zstd -q -o "$archive_path"
    else
      tar "${tar_args[@]}" | zstd -q -o "$archive_path"
    fi
    zstd -dc "$archive_path" | tar -tf - >/dev/null
    return
  fi

  die "tar.zst requires tar with --zstd support or a zstd binary"
}

# Project root: parent directory of this script directory
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALLER_PWD="$PWD"

DEFAULT_NAME="$(basename "$ROOT")"
DEFAULT_OUT_DIR="$ROOT/.."
DEFAULT_FORMAT="tar"

DEFAULT_EXCLUDES=(
  "__pycache__"
  ".pytest_cache"
  ".ruff_cache"
  "*.pyc"
  "*.pyo"
  "*.pyd"
  ".coverage"
  "htmlcov"
  ".venv"
  ".git"
  "build"
  "dist"
  "*.egg-info"
  "full_project_source.txt"
)

RUNTIME_EXCLUDES=(
  "artifacts"
  "cache"
  "data"
)

NAME="$DEFAULT_NAME"
OUT_DIR="$DEFAULT_OUT_DIR"
FORMAT="$DEFAULT_FORMAT"
USE_DEFAULT_EXCLUDES=true
EXCLUDE_RUNTIME=false
PROGRESS=false
SPLIT_SIZE=""
SPLIT_SIZE_BYTES=""
KEEP_ARCHIVE=false
WORK_DIR_BASE="${PACKAGE_REPO_TMPDIR:-}"
EXCLUDES=()
EXCLUDE_FILES=()
ZIP_EXCLUDE_ARGS=()
SPLIT_PARTS=()

POSITIONAL_INDEX=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  --name)
    require_value "$1" "${2-}"
    NAME="$2"
    shift 2
    ;;
  --out-dir)
    require_value "$1" "${2-}"
    OUT_DIR="$2"
    shift 2
    ;;
  --format)
    require_value "$1" "${2-}"
    FORMAT="$2"
    shift 2
    ;;
  --exclude-from)
    require_value "$1" "${2-}"
    EXCLUDE_FILES+=("$2")
    shift 2
    ;;
  --no-default-excludes)
    USE_DEFAULT_EXCLUDES=false
    shift
    ;;
  --source-only | --exclude-runtime)
    EXCLUDE_RUNTIME=true
    shift
    ;;
  --split-size)
    require_value "$1" "${2-}"
    SPLIT_SIZE="$2"
    shift 2
    ;;
  --keep-archive)
    KEEP_ARCHIVE=true
    shift
    ;;
  --work-dir)
    require_value "$1" "${2-}"
    WORK_DIR_BASE="$2"
    shift 2
    ;;
  --progress)
    PROGRESS=true
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  --)
    shift
    while [[ $# -gt 0 ]]; do
      case "$POSITIONAL_INDEX" in
      0) NAME="$1" ;;
      1) OUT_DIR="$1" ;;
      *) die "Too many positional arguments" ;;
      esac
      POSITIONAL_INDEX=$((POSITIONAL_INDEX + 1))
      shift
    done
    ;;
  -*)
    die "Unknown argument: $1"
    ;;
  *)
    case "$POSITIONAL_INDEX" in
    0) NAME="$1" ;;
    1) OUT_DIR="$1" ;;
    *) die "Too many positional arguments" ;;
    esac
    POSITIONAL_INDEX=$((POSITIONAL_INDEX + 1))
    shift
    ;;
  esac
done

[[ -n "$NAME" ]] || die "Archive name must not be empty"
[[ "$NAME" != */* ]] || die "Archive name must not contain path separators"

case "$FORMAT" in
tar) EXTENSION="tar" ;;
tar.gz) EXTENSION="tar.gz" ;;
zip) EXTENSION="zip" ;;
tar.zst) EXTENSION="tar.zst" ;;
*) die "Unsupported format: $FORMAT (expected tar, tar.gz, zip, or tar.zst)" ;;
esac

if [[ -n "$SPLIT_SIZE" ]]; then
  SPLIT_SIZE_BYTES="$(parse_size_to_bytes "$SPLIT_SIZE")"
fi

if [[ -z "$SPLIT_SIZE" && "$KEEP_ARCHIVE" == true ]]; then
  die "--keep-archive requires --split-size"
fi

OUT_DIR="$(resolve_path_arg "$OUT_DIR")"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
[[ -w "$OUT_DIR" ]] || die "Output directory is not writable: $OUT_DIR"

if [[ -z "$WORK_DIR_BASE" ]]; then
  WORK_DIR_BASE="$OUT_DIR"
else
  WORK_DIR_BASE="$(resolve_path_arg "$WORK_DIR_BASE")"
fi
mkdir -p "$WORK_DIR_BASE"
WORK_DIR_BASE="$(cd "$WORK_DIR_BASE" && pwd)"
[[ -w "$WORK_DIR_BASE" ]] || die "Work directory base is not writable: $WORK_DIR_BASE"

if [[ "$USE_DEFAULT_EXCLUDES" == true ]]; then
  EXCLUDES=("${DEFAULT_EXCLUDES[@]}")
fi

if [[ "$EXCLUDE_RUNTIME" == true ]]; then
  EXCLUDES+=("${RUNTIME_EXCLUDES[@]}")
fi

if [[ ${#EXCLUDE_FILES[@]} -gt 0 ]]; then
  for exclude_file in "${EXCLUDE_FILES[@]}"; do
    exclude_file="$(resolve_path_arg "$exclude_file")"
    load_exclude_file "$exclude_file"
  done
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
ARCHIVE_BASENAME="${NAME}_${STAMP}.${EXTENSION}"
WORK_DIR="$(mktemp -d -p "$WORK_DIR_BASE" "${NAME}.tmp.XXXXXXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

ARCHIVE_PATH="${WORK_DIR}/${ARCHIVE_BASENAME}"
FINAL_ARCHIVE_PATH="${OUT_DIR}/${ARCHIVE_BASENAME}"

cd "$ROOT"

case "$FORMAT" in
tar) create_tar "$ARCHIVE_PATH" ;;
tar.gz) create_tar_gz "$ARCHIVE_PATH" ;;
zip) create_zip "$ARCHIVE_PATH" ;;
tar.zst) create_tar_zst "$ARCHIVE_PATH" ;;
esac

checksum_file "$ARCHIVE_PATH"
ARCHIVE_SIZE_BYTES="$(file_size_bytes "$ARCHIVE_PATH")"

if [[ -n "$SPLIT_SIZE_BYTES" && "$ARCHIVE_SIZE_BYTES" -gt "$SPLIT_SIZE_BYTES" ]]; then
  PART_PREFIX="${ARCHIVE_PATH}.part-"
  FINAL_PART_PATHS=()
  split_archive "$ARCHIVE_PATH" "$PART_PREFIX"

  for part_path in "${SPLIT_PARTS[@]}"; do
    checksum_file "$part_path"
    final_part_path="${OUT_DIR}/$(basename "$part_path")"
    mv "$part_path" "$final_part_path"
    mv "${part_path}.sha256" "${final_part_path}.sha256"
    FINAL_PART_PATHS+=("$final_part_path")
  done

  if [[ "$KEEP_ARCHIVE" == true ]]; then
    mv "$ARCHIVE_PATH" "$FINAL_ARCHIVE_PATH"
  fi
  mv "${ARCHIVE_PATH}.sha256" "${FINAL_ARCHIVE_PATH}.sha256"

  write_split_manifest "$FINAL_ARCHIVE_PATH" "${FINAL_PART_PATHS[@]}"

  if [[ "$KEEP_ARCHIVE" == true ]]; then
    echo "Created: $FINAL_ARCHIVE_PATH"
  fi
  echo "Created split parts:"
  for final_part_path in "${FINAL_PART_PATHS[@]}"; do
    echo "  $final_part_path"
  done
  echo "Archive SHA256 : ${FINAL_ARCHIVE_PATH}.sha256"
  echo "Parts manifest : ${FINAL_ARCHIVE_PATH}.parts.txt"
else
  if [[ -n "$SPLIT_SIZE_BYTES" && "$PROGRESS" == true ]]; then
    echo "Archive is within split size; keeping a single archive."
  fi

  mv "$ARCHIVE_PATH" "$FINAL_ARCHIVE_PATH"
  mv "${ARCHIVE_PATH}.sha256" "${FINAL_ARCHIVE_PATH}.sha256"

  echo "Created: $FINAL_ARCHIVE_PATH"
  echo "SHA256 : ${FINAL_ARCHIVE_PATH}.sha256"
fi
