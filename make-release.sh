#!/usr/bin/env bash
set -euo pipefail

VERSION="v1.2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/out"
RELEASE_DIR_NAME="maxmind-csv2sql-converter-${VERSION}"
ARCHIVE_NAME="${RELEASE_DIR_NAME}.zip"
ARCHIVE_PATH="${OUT_DIR}/${ARCHIVE_NAME}"

RELEASE_ITEMS=(
  "configs"
  "generators"
  "maxmind-csv2sql-converter.sh"
  "convert-default.mysql.sh"
  "convert-default.postgresql.sh"
)

for item in "${RELEASE_ITEMS[@]}"; do
  if [[ ! -e "${SCRIPT_DIR}/${item}" ]]; then
    echo "Required release item is missing: ${item}" >&2
    exit 1
  fi
done

mkdir -p "${OUT_DIR}"
rm -f "${ARCHIVE_PATH}"

if command -v zip >/dev/null 2>&1; then
  STAGING_DIR="$(mktemp -d)"
  trap 'rm -rf "${STAGING_DIR}"' EXIT
  mkdir -p "${STAGING_DIR}/${RELEASE_DIR_NAME}"

  for item in "${RELEASE_ITEMS[@]}"; do
    cp -R "${SCRIPT_DIR}/${item}" "${STAGING_DIR}/${RELEASE_DIR_NAME}/"
  done

  (
    cd "${STAGING_DIR}" || exit
    zip -r -q "${ARCHIVE_PATH}" "${RELEASE_DIR_NAME}"
  )
else
  PYTHON_CMD=()
  for candidate in python3 python "py -3"; do
    read -r -a cmd <<< "$candidate"
    if command -v "${cmd[0]}" >/dev/null 2>&1 && "${cmd[@]}" -c 'import sys; raise SystemExit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1; then
      PYTHON_CMD=("${cmd[@]}")
      break
    fi
  done

  if [[ "${#PYTHON_CMD[@]}" -eq 0 ]]; then
    echo "Unable to create archive: install zip or make python3/python/py available in PATH." >&2
    exit 1
  fi

  "${PYTHON_CMD[@]}" - "${SCRIPT_DIR}" "${ARCHIVE_PATH}" "${RELEASE_DIR_NAME}" "${RELEASE_ITEMS[@]}" <<'PY'
import os
import sys
import zipfile

script_dir = sys.argv[1]
archive_path = sys.argv[2]
release_dir_name = sys.argv[3]
release_items = sys.argv[4:]

with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for item in release_items:
        source = os.path.join(script_dir, item)
        if os.path.isdir(source):
            for root, _, files in os.walk(source):
                for file_name in files:
                    file_path = os.path.join(root, file_name)
                    relative_path = os.path.relpath(file_path, script_dir)
                    archive.write(file_path, os.path.join(release_dir_name, relative_path))
        else:
            archive.write(source, os.path.join(release_dir_name, item))
PY
fi

echo "Created ${ARCHIVE_PATH}"
