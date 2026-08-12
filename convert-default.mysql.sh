#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/maxmind-csv2sql-converter.sh" -c "${SCRIPT_DIR}/configs/default.mysql.ini"
