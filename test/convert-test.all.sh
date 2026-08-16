#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit
mysql_pid=""
postgresql_pid=""
stopping=false

terminate_process_tree() {
  local pid="$1"
  local signal="$2"
  local child_pid
  local -a child_pids=()

  mapfile -t child_pids < <(
    ps -ef | awk -v parent_pid="$pid" '
      NR > 1 && $3 == parent_pid { print $2 }
    '
  )
  for child_pid in "${child_pids[@]}"; do
    terminate_process_tree "$child_pid" "$signal"
  done
  kill "-$signal" "$pid" 2>/dev/null || true
}

stop_converters() {
  local exit_status="$1"
  local pid
  local attempt
  local has_running_processes

  if [[ "$stopping" == "true" ]]; then
    exit "$exit_status"
  fi
  stopping=true
  trap '' INT TERM

  for pid in "$mysql_pid" "$postgresql_pid"; do
    [[ -n "$pid" ]] || continue
    terminate_process_tree "$pid" TERM
  done

  for ((attempt = 0; attempt < 20; attempt++)); do
    has_running_processes=false
    for pid in "$mysql_pid" "$postgresql_pid"; do
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        has_running_processes=true
      fi
    done
    [[ "$has_running_processes" == "true" ]] || break
    sleep 0.1
  done

  for pid in "$mysql_pid" "$postgresql_pid"; do
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      terminate_process_tree "$pid" KILL
    fi
    wait "$pid" 2>/dev/null || true
  done
  exit "$exit_status"
}

trap 'stop_converters 130' INT
trap 'stop_converters 143' TERM

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
