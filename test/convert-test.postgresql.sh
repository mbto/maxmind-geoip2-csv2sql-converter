#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit

bash "${PROJECT_DIR}/maxmind-csv2sql-converter.sh" -c "${SCRIPT_DIR}/test.postgresql.ini"
