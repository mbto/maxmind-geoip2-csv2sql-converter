#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit

run_convert() {
  local label="$1"
  local config="$2"
  bash "${PROJECT_DIR}/maxmind-csv2sql-converter.sh" -c "$config" 2>&1 | while IFS= read -r line; do
    printf '[%s] %s\n' "$label" "$line"
  done
}

run_convert mysql "${SCRIPT_DIR}/test.mysql.ini" &
mysql_pid="$!"

run_convert postgresql "${SCRIPT_DIR}/test.postgresql.ini" &
postgresql_pid="$!"

status=0
wait "$mysql_pid" || status=1
wait "$postgresql_pid" || status=1
exit "$status"
