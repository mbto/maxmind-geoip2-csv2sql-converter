#!/usr/bin/env bash
set -euo pipefail

readonly CONVERTER_VERSION="1.3"
readonly SCHEMA_VERSION=4
export CONVERTER_VERSION SCHEMA_VERSION

usage() {
  cat <<USAGE
https://github.com/mbto/maxmind-csv2sql-converter v$CONVERTER_VERSION

Usage:
  maxmind-csv2sql-converter.sh -c path/to/config.ini
  maxmind-csv2sql-converter.sh -c path/to/config.ini --list-editions

Config file names must follow:
  project_name.database_type.ini

Examples:
  default.mysql.ini
  default.postgresql.ini
  production.mysql.ini
  production.postgresql.ini

The script downloads or reads a MaxMind GeoIP/GeoIP2/GeoLite2 CSV ZIP archive,
extracts the CSV files, generates SQL that imports raw CSV data into the
database, builds normalized staging tables there, and atomically promotes the
new tables to production names.

Requirements:
  bash 5+, awk, unzip, curl for HTTP(S) downloads, mysql or psql when settings.auto_execute_loader_sh=true
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

CONFIG_PATH=""
LIST_EDITIONS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      CONFIG_PATH="$2"
      shift 2
      ;;
    --list-editions)
      LIST_EDITIONS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$CONFIG_PATH" ]] || { usage >&2; exit 2; }
[[ -f "$CONFIG_PATH" ]] || die "Config not found: $CONFIG_PATH"

need_cmd awk

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
CONFIG_DIR="$(cd -- "$(dirname "$CONFIG_PATH")" >/dev/null 2>&1 && pwd -P)"
CONFIG_PATH="$CONFIG_DIR/$(basename "$CONFIG_PATH")"

CONFIG_BASENAME="$(basename "$CONFIG_PATH")"
CONFIG_STEM="${CONFIG_BASENAME%.ini}"
[[ "$CONFIG_BASENAME" == *.ini ]] || die "Config file must end with .ini"
[[ "$CONFIG_STEM" == *.* ]] || die "Config file name must follow project_name.database_type.ini"

CONFIG_PROJECT_NAME="${CONFIG_STEM%.*}"
CONFIG_DBMS="${CONFIG_STEM##*.}"
CONFIG_DBMS="${CONFIG_DBMS,,}"

[[ "$CONFIG_DBMS" == "mysql" || "$CONFIG_DBMS" == "postgresql" ]] || die "Unsupported database type in config filename: $CONFIG_DBMS"
[[ -n "$CONFIG_PROJECT_NAME" && "$CONFIG_PROJECT_NAME" != "$CONFIG_DBMS" ]] || die "Project name is missing in config filename"
CONFIG_EDITION_ID=""
CONFIG_EDITION_VENDOR=""
CONFIG_EDITION_KIND=""
declare -gA CONFIG_VALUES=()
declare -gA CONFIG_SECTIONS=()
declare -gA CONFIG_SECTION_PAIRS=()
declare -gA CONFIG_LIST_VALUES=()
declare -gA HEADER_COLUMNS_CACHE=()
declare -gA CSV_HAS_COLUMN_CACHE=()
declare -gA SQL_LITERAL_CACHE=()
declare -gA MYSQL_IDENT_CACHE=()
declare -gA PG_IDENT_CACHE=()
declare -gA IDENT_CACHE=()
declare -gA LOCALE_ALIAS_CACHE=()
declare -gA RAW_LOCATION_TABLE_CACHE=()
declare -gA RAW_BLOCKS_TABLE_CACHE=()
declare -gA TO_CLIENT_PATH_CACHE=()

cfg_get_exact() {
  local section="$1"
  local key="$2"
  local default="${3-}"
  local cache_key value
  cache_key="${section}"$'\034'"${key}"$'\034'"${default}"
  if [[ -v 'CFG_GET_EXACT_CACHE[$cache_key]' ]]; then
    printf '%s\n' "${CFG_GET_EXACT_CACHE[$cache_key]}"
    return
  fi
  value="$(awk -v want_section="$section" -v want_key="$key" -v default_value="$default" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function strip_comment(s,    i, c, q, out, prev) {
      out = ""
      q = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") {
          out = out c
          if (c == q) q = ""
          continue
        }
        if (c == "\"" || c == "'\''") {
          q = c
          out = out c
          continue
        }
        prev = i == 1 ? " " : substr(s, i - 1, 1)
        if ((c == "#" || c == ";") && prev ~ /[[:space:]]/) break
        out = out c
      }
      return trim(out)
    }
    function unquote(s) {
      s = strip_comment(s)
      if ((substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") ||
          (substr(s, 1, 1) == "'\''" && substr(s, length(s), 1) == "'\''")) {
        return substr(s, 2, length(s) - 2)
      }
      return s
    }
    BEGIN { section = ""; found = 0 }
    {
      sub(/\r$/, "")
      sub(/^\xef\xbb\xbf/, "")
      line = $0
      s = trim(line)
      if (s == "" || s ~ /^(#|;|\/\/)/) next
      if (s ~ /^\[[^]]+\]$/) {
        section = substr(s, 2, length(s) - 2)
        next
      }
      if (section == want_section) {
        pos = index(line, "=")
        if (pos > 0) {
          k = trim(substr(line, 1, pos - 1))
          if (k == want_key) {
            print unquote(substr(line, pos + 1))
            found = 1
            exit
          }
        }
      }
    }
    END { if (!found) print default_value }
  ' "$CONFIG_PATH")"
  CFG_GET_EXACT_CACHE[$cache_key]="$value"
  printf '%s\n' "$value"
}

section_pairs_exact() {
  local wanted="$1"
  local value
  if [[ -v 'SECTION_PAIRS_EXACT_CACHE[$wanted]' ]]; then
    [[ -n "${SECTION_PAIRS_EXACT_CACHE[$wanted]}" ]] && printf '%s\n' "${SECTION_PAIRS_EXACT_CACHE[$wanted]}"
    return
  fi
  value="$(awk -v want_section="$wanted" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function strip_comment(s,    i, c, q, out, prev) {
      out = ""
      q = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") {
          out = out c
          if (c == q) q = ""
          continue
        }
        if (c == "\"" || c == "'\''") {
          q = c
          out = out c
          continue
        }
        prev = i == 1 ? " " : substr(s, i - 1, 1)
        if ((c == "#" || c == ";") && prev ~ /[[:space:]]/) break
        out = out c
      }
      return trim(out)
    }
    function unquote(s) {
      s = strip_comment(s)
      if ((substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") ||
          (substr(s, 1, 1) == "'\''" && substr(s, length(s), 1) == "'\''")) {
        return substr(s, 2, length(s) - 2)
      }
      return s
    }
    BEGIN { section = "" }
    {
      sub(/\r$/, "")
      sub(/^\xef\xbb\xbf/, "")
      line = $0
      s = trim(line)
      if (s == "" || s ~ /^(#|;|\/\/)/) next
      if (s ~ /^\[[^]]+\]$/) {
        section = substr(s, 2, length(s) - 2)
        next
      }
      if (section == want_section) {
        pos = index(line, "=")
        if (pos > 0) {
          key = trim(substr(line, 1, pos - 1))
          value = unquote(substr(line, pos + 1))
          if (key != "" && value != "") print key "\t" value
        }
      }
    }
  ' "$CONFIG_PATH")"
  SECTION_PAIRS_EXACT_CACHE[$wanted]="$value"
  [[ -n "$value" ]] && printf '%s\n' "$value"
}

section_exists() {
  local wanted="$1"
  local status
  if [[ -v 'SECTION_EXISTS_CACHE[$wanted]' ]]; then
    return "${SECTION_EXISTS_CACHE[$wanted]}"
  fi
  if awk -v want_section="$wanted" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    {
      sub(/\r$/, "")
      sub(/^\xef\xbb\xbf/, "")
      s = trim($0)
      if (s ~ /^\[[^]]+\]$/) {
        section = substr(s, 2, length(s) - 2)
        if (section == want_section) {
          found = 1
          exit
        }
      }
    }
    END { exit found ? 0 : 1 }
  ' "$CONFIG_PATH"; then
    status=0
  else
    status=1
  fi
  SECTION_EXISTS_CACHE[$wanted]="$status"
  return "$status"
}

cfg_get() {
  local section="$1"
  local key="$2"
  local default="${3-}"
  local scoped missing
  missing=$'\001__maxmind_cfg_missing__\001'
  if [[ -n "${CONFIG_EDITION_ID:-}" ]]; then
    scoped="$(cfg_get_exact "$CONFIG_EDITION_ID.$section" "$key" "$missing")"
    if [[ "$scoped" != "$missing" ]]; then
      printf '%s\n' "$scoped"
      return
    fi
  fi
  cfg_get_exact "$section" "$key" "$default"
}

cfg_get_setting() {
  local key="$1"
  local default="${2-}"
  cfg_get_exact settings "$key" "$default"
}

section_pairs() {
  local section="$1"
  if [[ -n "${CONFIG_EDITION_ID:-}" ]] && section_exists "$CONFIG_EDITION_ID.$section"; then
    section_pairs_exact "$CONFIG_EDITION_ID.$section"
    return
  fi
  section_pairs_exact "$section"
}

split_config_list() {
  awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function emit(v) {
      v = trim(v)
      if (v != "") print v
    }
    {
      field = ""
      inq = 0
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (inq) {
          if (c == "\"") {
            if (substr($0, i + 1, 1) == "\"") {
              field = field "\""
              i++
            } else {
              inq = 0
            }
          } else {
            field = field c
          }
        } else if (c == "\"") {
          inq = 1
        } else if (c == ",") {
          emit(field)
          field = ""
        } else {
          field = field c
        }
      }
      emit(field)
    }
  '
}

config_list_values() {
  local wanted="$1"
  local key_name="$2"
  local cache_key value
  cache_key="${wanted}"$'\034'"${key_name}"
  if [[ -v 'CONFIG_LIST_VALUES_CACHE[$cache_key]' ]]; then
    [[ -n "${CONFIG_LIST_VALUES_CACHE[$cache_key]}" ]] && printf '%s\n' "${CONFIG_LIST_VALUES_CACHE[$cache_key]}"
    return
  fi
  value="$(awk -v want_section="$wanted" -v want_key="$key_name" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function strip_comment(s,    i, c, q, out, prev) {
      out = ""
      q = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") {
          out = out c
          if (c == q) q = ""
          continue
        }
        if (c == "\"" || c == "'\''") {
          q = c
          out = out c
          continue
        }
        prev = i == 1 ? " " : substr(s, i - 1, 1)
        if ((c == "#" || c == ";") && prev ~ /[[:space:]]/) break
        out = out c
      }
      return trim(out)
    }
    function unquote(s) {
      s = strip_comment(s)
      if ((substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") ||
          (substr(s, 1, 1) == "'\''" && substr(s, length(s), 1) == "'\''")) {
        return substr(s, 2, length(s) - 2)
      }
      return s
    }
    function emit(s) {
      s = unquote(s)
      if (s != "") print s
    }
    BEGIN { section = ""; collect = 0 }
    {
      sub(/\r$/, "")
      sub(/^\xef\xbb\xbf/, "")
      line = $0
      s = trim(line)
      if (s ~ /^\[[^]]+\]$/) {
        section = substr(s, 2, length(s) - 2)
        collect = 0
        next
      }
      if (s == "" || s ~ /^(#|;|\/\/)/ || section != want_section) next
      pos = index(line, "=")
      if (pos > 0) {
        key = trim(substr(line, 1, pos - 1))
        if (key == want_key) {
          emit(substr(line, pos + 1))
          collect = 1
          next
        }
        if (collect) collect = 0
      }
      if (collect) emit(line)
    }
  ' "$CONFIG_PATH")"
  CONFIG_LIST_VALUES_CACHE[$cache_key]="$value"
  [[ -n "$value" ]] && printf '%s\n' "$value"
}

append_config_cache_value() {
  local -n target_ref="$1"
  local key="$2"
  local value="$3"
  if [[ -v 'target_ref[$key]' && -n "${target_ref[$key]}" ]]; then
    target_ref[$key]+=$'\n'"$value"
  else
    target_ref[$key]="$value"
  fi
}

load_config_cache() {
  local kind section key value map_key
  CONFIG_VALUES=()
  CONFIG_SECTIONS=()
  CONFIG_SECTION_PAIRS=()
  CONFIG_LIST_VALUES=()
  while IFS=$'\034' read -r kind section key value; do
    case "$kind" in
      section)
        CONFIG_SECTIONS[$section]=1
        ;;
      exact)
        map_key="${section}"$'\034'"${key}"
        if [[ ! -v 'CONFIG_VALUES[$map_key]' ]]; then
          CONFIG_VALUES[$map_key]="$value"
        fi
        ;;
      pair)
        append_config_cache_value CONFIG_SECTION_PAIRS "$section" "${key}"$'\t'"${value}"
        ;;
      list)
        map_key="${section}"$'\034'"${key}"
        append_config_cache_value CONFIG_LIST_VALUES "$map_key" "$value"
        ;;
    esac
  done < <(awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function strip_comment(s,    i, c, q, out, prev, singleq) {
      singleq = sprintf("%c", 39)
      out = ""
      q = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") {
          out = out c
          if (c == q) q = ""
          continue
        }
        if (c == "\"" || c == singleq) {
          q = c
          out = out c
          continue
        }
        prev = i == 1 ? " " : substr(s, i - 1, 1)
        if ((c == "#" || c == ";") && prev ~ /[[:space:]]/) break
        out = out c
      }
      return trim(out)
    }
    function unquote(s,    first, last, singleq) {
      singleq = sprintf("%c", 39)
      s = strip_comment(s)
      first = substr(s, 1, 1)
      last = substr(s, length(s), 1)
      if ((first == "\"" && last == "\"") || (first == singleq && last == singleq)) {
        return substr(s, 2, length(s) - 2)
      }
      return s
    }
    function emit(kind, section, key, value) {
      print kind sep section sep key sep value
    }
    BEGIN {
      sep = "\034"
      section = ""
      collect_key = ""
    }
    {
      sub(/\r$/, "")
      sub(/^\xef\xbb\xbf/, "")
      line = $0
      s = trim(line)
      if (s ~ /^\[[^]]+\]$/) {
        section = substr(s, 2, length(s) - 2)
        collect_key = ""
        emit("section", section, "", "")
        next
      }
      if (s == "" || s ~ /^(#|;|\/\/)/ || section == "") next
      pos = index(line, "=")
      if (pos > 0) {
        key = trim(substr(line, 1, pos - 1))
        value = unquote(substr(line, pos + 1))
        emit("exact", section, key, value)
        if (key != "" && value != "") {
          emit("pair", section, key, value)
          emit("list", section, key, value)
        }
        collect_key = key
        next
      }
      if (collect_key != "") {
        value = unquote(line)
        if (value != "") emit("list", section, collect_key, value)
      }
    }
  ' "$CONFIG_PATH")
}

cfg_get_exact() {
  local section="$1"
  local key="$2"
  local default="${3-}"
  local map_key
  map_key="${section}"$'\034'"${key}"
  if [[ -v 'CONFIG_VALUES[$map_key]' ]]; then
    printf '%s\n' "${CONFIG_VALUES[$map_key]}"
  else
    printf '%s\n' "$default"
  fi
}

section_exists() {
  local wanted="$1"
  [[ -v 'CONFIG_SECTIONS[$wanted]' ]]
}

section_pairs() {
  local section="$1"
  local scoped
  if [[ -n "${CONFIG_EDITION_ID:-}" ]]; then
    scoped="$CONFIG_EDITION_ID.$section"
    if section_exists "$scoped"; then
      [[ -n "${CONFIG_SECTION_PAIRS[$scoped]:-}" ]] && printf '%s\n' "${CONFIG_SECTION_PAIRS[$scoped]}"
      return
    fi
  fi
  [[ -n "${CONFIG_SECTION_PAIRS[$section]:-}" ]] && printf '%s\n' "${CONFIG_SECTION_PAIRS[$section]}"
}

config_list_values() {
  local wanted="$1"
  local key_name="$2"
  local map_key
  map_key="${wanted}"$'\034'"${key_name}"
  [[ -n "${CONFIG_LIST_VALUES[$map_key]:-}" ]] && printf '%s\n' "${CONFIG_LIST_VALUES[$map_key]}"
}

load_config_cache

list_config_editions() {
  local raw
  raw="$(config_list_values editions edition_ids)"
  [[ -n "$raw" ]] || raw="$(config_list_values editions enabled)"
  [[ -n "$raw" ]] || raw="$(cfg_get_exact download edition_id "")"
  [[ -n "$raw" ]] || return 0
  printf '%s\n' "$raw" | split_config_list
}

to_unix_path() {
  local raw="${1//\\//}"
  if [[ "$raw" =~ ^([A-Za-z]):/(.*)$ ]]; then
    if command -v cygpath >/dev/null 2>&1; then
      cygpath -u "$raw"
    else
      local drive="${BASH_REMATCH[1],,}"
      local rest="${BASH_REMATCH[2]}"
      if [[ -d "/mnt/$drive" ]]; then
        printf '/mnt/%s/%s\n' "$drive" "$rest"
      else
        printf '%s\n' "$raw"
      fi
    fi
  else
    printf '%s\n' "$raw"
  fi
}

to_client_path() {
  local raw="$1"
  local value
  if [[ -v 'TO_CLIENT_PATH_CACHE[$raw]' ]]; then
    printf '%s\n' "${TO_CLIENT_PATH_CACHE[$raw]}"
    return
  fi
  if command -v cygpath >/dev/null 2>&1; then
    value="$(cygpath -m "$raw")"
  else
    value="$raw"
  fi
  TO_CLIENT_PATH_CACHE[$raw]="$value"
  printf '%s\n' "$value"
}

resolve_path() {
  local raw="$1"
  local base_dir="$2"
  [[ -n "$raw" ]] || return 1
  raw="$(to_unix_path "$raw")"
  if [[ "$raw" == /* ]]; then
    printf '%s\n' "$raw"
  else
    printf '%s/%s\n' "$base_dir" "$raw"
  fi
}

bool_value() {
  local raw="${1,,}"
  local default="$2"
  [[ -n "$raw" ]] || { printf '%s\n' "$default"; return; }
  case "$raw" in
    1|true|yes|y|on) printf 'true\n' ;;
    0|false|no|n|off) printf 'false\n' ;;
    *) die "Invalid boolean value: $1" ;;
  esac
}

int_value() {
  local raw="$1"
  local default="$2"
  local min="$3"
  [[ -n "$raw" ]] || raw="$default"
  [[ "$raw" =~ ^[0-9]+$ ]] || die "Invalid integer value: $raw"
  (( raw >= min )) || die "Integer value must be >= $min: $raw"
  printf '%s\n' "$raw"
}

debug_now_ms() {
  local value
  value="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s000\n' "$(date +%s)"
  fi
}

debug_format_elapsed() {
  local elapsed_ms="$1"
  printf '%d.%03ds' "$((elapsed_ms / 1000))" "$((elapsed_ms % 1000))"
}

debug_enabled() {
  [[ "${ON_DEBUG:-false}" == "true" ]]
}

debug_log() {
  debug_enabled || return 0
  printf '[debug] %s\n' "$*" >&2
}

debug_begin() {
  local -n start_ref="$1"
  local label="$2"
  start_ref="$(debug_now_ms)"
  debug_log "start: $label"
}

debug_end() {
  local label="$1"
  local start_ms="$2"
  local end_ms elapsed_ms
  debug_enabled || return 0
  end_ms="$(debug_now_ms)"
  elapsed_ms=$((end_ms - start_ms))
  debug_log "done: $label ($(debug_format_elapsed "$elapsed_ms"))"
}

debug_step() {
  local label="$1"
  shift
  local start_ms end_ms elapsed_ms status
  if ! debug_enabled; then
    "$@"
    return
  fi
  start_ms="$(debug_now_ms)"
  debug_log "start: $label"
  set +e
  "$@"
  status="$?"
  set -e
  end_ms="$(debug_now_ms)"
  elapsed_ms=$((end_ms - start_ms))
  if [[ "$status" -eq 0 ]]; then
    debug_log "done: $label ($(debug_format_elapsed "$elapsed_ms"))"
  else
    debug_log "failed: $label ($(debug_format_elapsed "$elapsed_ms"), status $status)"
  fi
  return "$status"
}

ON_DEBUG="$(bool_value "${ON_DEBUG:-$(cfg_get_setting on_debug "false")}" false)"
export ON_DEBUG
DEBUG_PROCESS_START_MS="$(debug_now_ms)"

sql_literal() {
  local s="$1"
  local value
  if [[ -v 'SQL_LITERAL_CACHE[$s]' ]]; then
    printf '%s' "${SQL_LITERAL_CACHE[$s]}"
    return
  fi
  value="${s//\'/\'\'}"
  value="'$value'"
  SQL_LITERAL_CACHE[$s]="$value"
  printf '%s' "$value"
}

mysql_ident() {
  local s="$1"
  local value
  if [[ -v 'MYSQL_IDENT_CACHE[$s]' ]]; then
    printf '%s' "${MYSQL_IDENT_CACHE[$s]}"
    return
  fi
  value="${s//\`/\`\`}"
  value="\`$value\`"
  MYSQL_IDENT_CACHE[$s]="$value"
  printf '%s' "$value"
}

pg_ident() {
  local s="$1"
  local value
  if [[ -v 'PG_IDENT_CACHE[$s]' ]]; then
    printf '%s' "${PG_IDENT_CACHE[$s]}"
    return
  fi
  value="${s//\"/\"\"}"
  value="\"$value\""
  PG_IDENT_CACHE[$s]="$value"
  printf '%s' "$value"
}

ident() {
  local s="$1"
  local cache_key value
  cache_key="${DBMS}"$'\034'"${s}"
  if [[ -v 'IDENT_CACHE[$cache_key]' ]]; then
    printf '%s' "${IDENT_CACHE[$cache_key]}"
    return
  fi
  if [[ "$DBMS" == "mysql" ]]; then
    value="${s//\`/\`\`}"
    value="\`$value\`"
  else
    value="${s//\"/\"\"}"
    value="\"$value\""
  fi
  IDENT_CACHE[$cache_key]="$value"
  printf '%s' "$value"
}

locale_alias() {
  local raw="$1"
  local s
  if [[ -v 'LOCALE_ALIAS_CACHE[$raw]' ]]; then
    printf '%s' "${LOCALE_ALIAS_CACHE[$raw]}"
    return
  fi
  s="${raw,,}"
  s="${s//[^a-z0-9_]/_}"
  LOCALE_ALIAS_CACHE[$raw]="$s"
  printf '%s' "$s"
}

raw_location_table() {
  local raw="$1"
  local value
  if [[ -v 'RAW_LOCATION_TABLE_CACHE[$raw]' ]]; then
    printf '%s' "${RAW_LOCATION_TABLE_CACHE[$raw]}"
    return
  fi
  value="raw_locations_$(locale_alias "$raw")__load_$RUN_ID"
  RAW_LOCATION_TABLE_CACHE[$raw]="$value"
  printf '%s' "$value"
}

raw_blocks_table() {
  local raw="$1"
  local value
  if [[ -v 'RAW_BLOCKS_TABLE_CACHE[$raw]' ]]; then
    printf '%s' "${RAW_BLOCKS_TABLE_CACHE[$raw]}"
    return
  fi
  value="raw_blocks_ipv${raw}__load_$RUN_ID"
  RAW_BLOCKS_TABLE_CACHE[$raw]="$value"
  printf '%s' "$value"
}

validate_csv_values() {
  local raw="$1"
  local allowed="$2"
  local name="$3"
  local value
  [[ -n "$raw" ]] || die "$name must not be empty"
  while IFS= read -r value; do
    [[ -n "$value" ]] || continue
    case ",$allowed," in
      *,"$value",*) ;;
      *) die "Unsupported $name value: $value" ;;
    esac
  done < <(printf '%s\n' "$raw" | split_config_list)
}

array_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

collect_proxies() {
  local proxy_file="$1"
  [[ -n "$proxy_file" ]] || return 0
  awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    {
      sub(/\r$/, "")
      s = trim($0)
      if (s != "" && s !~ /^(#|;|\/\/)/ && !seen[s]++) print s
    }
  ' "$proxy_file"
}

zip_is_valid() {
  unzip -tq "$1" >/dev/null 2>&1
}

file_size() {
  wc -c < "$1" | tr -d '[:space:]'
}

is_http_uri() {
  [[ "$1" == http://* || "$1" == https://* ]]
}

local_archive_source_path() {
  local source="$1"
  if [[ "$source" == file://* ]]; then
    source="${source#file://}"
    if [[ "$source" =~ ^/[A-Za-z]:/ ]]; then
      source="${source#/}"
    fi
  fi
  resolve_path "$source" "$CONFIG_DIR"
}

http_content_length() {
  local source="$1"
  local attempt="$2"
  local headers length
  local cmd=(curl --fail --location --silent --show-error --head
    --connect-timeout "$CONNECT_TIMEOUT"
    --max-time "$CONNECT_TIMEOUT"
    --retry "$RETRIES")
  if [[ "$attempt" != "__direct__" ]]; then
    cmd+=(--proxy "$attempt")
  fi
  headers="$("${cmd[@]}" "$source" 2>/dev/null)" || return 1
  length="$(printf '%s\n' "$headers" | awk '
    BEGIN { IGNORECASE = 1 }
    {
      sub(/\r$/, "")
      if ($0 ~ /^Content-Length:[[:space:]]*[0-9]+[[:space:]]*$/) {
        sub(/^[^:]+:[[:space:]]*/, "", $0)
        sub(/[[:space:]]+$/, "", $0)
        value = $0
      }
    }
    END { if (value ~ /^[0-9]+$/) print value }
  ')"
  [[ "$length" =~ ^[0-9]+$ && "$length" -gt 0 ]] || return 1
  printf '%s\n' "$length"
}

download_archive() {
  local source="$1"
  local archive_cache_dir="$OUTPUT_DIR/_archives"
  local archive_path tmp_path hash attempt label proxy proxy_file size remote_size cached_size
  mkdir -p "$archive_cache_dir"

  if ! is_http_uri "$source"; then
    source="$(local_archive_source_path "$source")"
    [[ -f "$source" ]] || die "Source archive file does not exist: $source"
    debug_step "validate local ZIP" zip_is_valid "$source" || die "Source archive is not a valid ZIP: $source"
    printf '%s\n' "$source"
    return
  fi

  need_cmd curl
  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$source" | sha256sum | awk '{ print substr($1, 1, 16) }')"
  else
    hash="$(printf '%s' "$source" | cksum | awk '{ print $1 }')"
  fi
  archive_path="$archive_cache_dir/maxmind-$hash.zip"
  tmp_path="$archive_path.part"

  local attempts=()
  if [[ "$TRY_WITHOUT_PROXY" == "true" ]]; then
    attempts+=("__direct__")
  fi
  proxy_file=""
  if [[ -n "$PROXY_FILE_RAW" ]]; then
    proxy_file="$(resolve_path "$PROXY_FILE_RAW" "$CONFIG_DIR")"
    [[ -f "$proxy_file" ]] || die "download.proxy_file not found: $proxy_file"
  fi
  while IFS= read -r proxy; do
    [[ -n "$proxy" ]] && attempts+=("$proxy")
  done < <(collect_proxies "$proxy_file")
  if [[ "${#attempts[@]}" -eq 0 ]]; then
    die "No HTTP download attempts configured: set download.try_without_proxy=true or provide download.proxy_file with at least one proxy"
  fi

  for attempt in "${attempts[@]}"; do
    if [[ "$attempt" == "__direct__" ]]; then
      label="direct connection"
    else
      label="proxy $attempt"
    fi

    remote_size=""
    if remote_size="$(debug_step "HEAD archive via $label" http_content_length "$source" "$attempt")"; then
      if [[ -f "$archive_path" ]]; then
        cached_size="$(file_size "$archive_path")"
        if [[ "$cached_size" == "$remote_size" ]]; then
          if debug_step "validate cached ZIP" zip_is_valid "$archive_path"; then
            info "Using cached archive from $archive_path ($cached_size bytes; matches Content-Length via $label)" >&2
            printf '%s\n' "$archive_path"
            return
          fi
          info "Cached archive size matches Content-Length via $label, but the file is not a valid ZIP; redownloading" >&2
        else
          info "Cached archive size differs from Content-Length via $label ($cached_size != $remote_size); redownloading" >&2
        fi
      fi
    else
      info "Remote archive size is unavailable via $label; downloading" >&2
    fi

    rm -f -- "$tmp_path"
    local cmd=(curl --fail --location --silent --show-error
      --connect-timeout "$CONNECT_TIMEOUT"
      --max-time "$MAX_TIME"
      --retry "$RETRIES"
      --output "$tmp_path")
    if [[ "$attempt" != "__direct__" ]]; then
      cmd+=(--proxy "$attempt")
    fi
    info "Downloading archive using $label" >&2
    if ! debug_step "download archive via $label" "${cmd[@]}" "$source"; then
      info "Download failed via $label" >&2
      continue
    fi
    if ! debug_step "validate downloaded ZIP" zip_is_valid "$tmp_path"; then
      size=0
      [[ -f "$tmp_path" ]] && size="$(wc -c < "$tmp_path" | tr -d '[:space:]')"
      info "Downloaded response via $label is not a ZIP ($size bytes)" >&2
      continue
    fi
    mv -f -- "$tmp_path" "$archive_path"
    printf '%s\n' "$archive_path"
    return
  done

  die "Unable to download a valid ZIP archive using configured direct/proxy attempts"
}

if [[ "$LIST_EDITIONS" == "true" ]]; then
  info "https://github.com/mbto/maxmind-csv2sql-converter v$CONVERTER_VERSION"
  list_config_editions
  exit 0
fi

CONFIG_EDITIONS=()
mapfile -t CONFIG_EDITIONS < <(list_config_editions)

if [[ -z "${MAXMIND_CSV2SQL_SELECTED_EDITION:-}" && "${#CONFIG_EDITIONS[@]}" -gt 0 ]]; then
  info "https://github.com/mbto/maxmind-csv2sql-converter v$CONVERTER_VERSION"
  debug_log "debug enabled"
  BUILD_RUN_ID="${MAXMIND_CSV2SQL_BUILD_RUN_ID:-b$(date -u +%Y%m%dT%H%M%SZ)_$$}"
  for edition in "${CONFIG_EDITIONS[@]}"; do
    [[ "$edition" =~ ^(GeoIP2|GeoLite2|GeoIP)-[A-Za-z0-9-]+-CSV$ ]] || die "Unsupported edition in editions.edition_ids: $edition"
  done
  for ((edition_index = 0; edition_index < ${#CONFIG_EDITIONS[@]}; edition_index++)); do
    edition="${CONFIG_EDITIONS[$edition_index]}"
    first=false
    final=false
    (( edition_index == 0 )) && first=true
    (( edition_index == ${#CONFIG_EDITIONS[@]} - 1 )) && final=true
    info "Converting $edition using $CONFIG_BASENAME"
    if [[ "$first" == "true" ]]; then
      debug_step "convert $edition" env \
        MAXMIND_CSV2SQL_SELECTED_EDITION="$edition" \
        MAXMIND_CSV2SQL_RESET_OUTPUT=true \
        MAXMIND_CSV2SQL_APPEND_OUTPUT=false \
        MAXMIND_CSV2SQL_FINAL_OUTPUT="$final" \
        MAXMIND_CSV2SQL_BUILD_RUN_ID="$BUILD_RUN_ID" \
        bash "$SCRIPT_PATH" -c "$CONFIG_PATH"
    else
      debug_step "convert $edition" env \
        MAXMIND_CSV2SQL_SELECTED_EDITION="$edition" \
        MAXMIND_CSV2SQL_RESET_OUTPUT=false \
        MAXMIND_CSV2SQL_APPEND_OUTPUT=true \
        MAXMIND_CSV2SQL_FINAL_OUTPUT="$final" \
        MAXMIND_CSV2SQL_BUILD_RUN_ID="$BUILD_RUN_ID" \
        bash "$SCRIPT_PATH" -c "$CONFIG_PATH"
    fi
  done
  debug_end "all editions" "$DEBUG_PROCESS_START_MS"
  exit 0
fi

need_cmd unzip
: "${MAXMIND_CSV2SQL_FINAL_OUTPUT:=true}"

CONFIG_EDITION_ID="${MAXMIND_CSV2SQL_SELECTED_EDITION:-}"
if [[ -z "$CONFIG_EDITION_ID" ]]; then
  CONFIG_EDITION_ID="$(cfg_get_exact download edition_id "")"
fi
if [[ -z "$CONFIG_EDITION_ID" && "$CONFIG_PROJECT_NAME" =~ ^(GeoIP2|GeoLite2|GeoIP)-[A-Za-z0-9-]+-CSV$ ]]; then
  CONFIG_EDITION_ID="$CONFIG_PROJECT_NAME"
fi
if [[ -z "$CONFIG_EDITION_ID" && "${#CONFIG_EDITIONS[@]}" -eq 1 ]]; then
  CONFIG_EDITION_ID="${CONFIG_EDITIONS[0]}"
fi
if [[ -z "$CONFIG_EDITION_ID" ]]; then
  die "download.edition_id or editions.edition_ids is required"
fi
[[ "$CONFIG_EDITION_ID" =~ ^(GeoIP2|GeoLite2|GeoIP)-[A-Za-z0-9-]+-CSV$ ]] || die "Unsupported or missing download.edition_id: $CONFIG_EDITION_ID"
CONFIG_EDITION_VENDOR="${BASH_REMATCH[1]}"
CONFIG_EDITION_KIND="${CONFIG_EDITION_ID#$CONFIG_EDITION_VENDOR-}"
CONFIG_EDITION_KIND="${CONFIG_EDITION_KIND%-CSV}"
if [[ "${#CONFIG_EDITIONS[@]}" -gt 0 ]] && ! array_contains "$CONFIG_EDITION_ID" "${CONFIG_EDITIONS[@]}"; then
  die "Edition $CONFIG_EDITION_ID is not listed in [editions]. Available editions: ${CONFIG_EDITIONS[*]}"
fi
CONFIG_SECTION_EDITION_ID="$(cfg_get download edition_id "$CONFIG_EDITION_ID")"
if [[ "$CONFIG_SECTION_EDITION_ID" != "$CONFIG_EDITION_ID" ]]; then
  die "download.edition_id ($CONFIG_SECTION_EDITION_ID) must match selected edition ($CONFIG_EDITION_ID)"
fi
SOURCE_ARCHIVE_URI="$(cfg_get download source_archive_uri "")"
LICENSE_KEY="$(cfg_get download license_key "")"
TRY_WITHOUT_PROXY="$(bool_value "$(cfg_get download try_without_proxy "true")" true)"
CONNECT_TIMEOUT="$(int_value "$(cfg_get download connect_timeout_seconds "5")" 5 1)"
MAX_TIME="$(int_value "$(cfg_get download max_time_seconds "1800")" 1800 1)"
RETRIES="$(int_value "$(cfg_get download retries "2")" 2 0)"
PROXY_FILE_RAW="$(cfg_get download proxy_file "")"
[[ -n "$PROXY_FILE_RAW" ]] || PROXY_FILE_RAW="$(cfg_get download proxy_path "")"

DBMS_OVERRIDE="$(cfg_get database dbms "")"
if [[ -n "$DBMS_OVERRIDE" && "${DBMS_OVERRIDE,,}" != "$CONFIG_DBMS" ]]; then
  die "database.dbms (${DBMS_OVERRIDE}) must match config filename database type (${CONFIG_DBMS})"
fi
DBMS="$CONFIG_DBMS"
SCHEMA_NAME="$(cfg_get database schema_name "")"
AUTO_EXECUTE_LOADER_SH="$(bool_value "$(cfg_get_setting auto_execute_loader_sh "false")" false)"
MYSQL_COMMAND="$(cfg_get_setting mysql_command "mysql")"
MYSQL_HOST="$(cfg_get_setting mysql_host "127.0.0.1")"
MYSQL_PORT="$(cfg_get_setting mysql_port "3306")"
MYSQL_USER="$(cfg_get_setting mysql_user "root")"
MYSQL_PASSWORD="$(cfg_get_setting mysql_password "")"
MYSQL_EXTRA_ARGS="$(cfg_get_setting mysql_extra_args "")"
MYSQL_ROUTINE_DEFINER="$(cfg_get_setting mysql_routine_definer "")"
POSTGRESQL_COMMAND="$(cfg_get_setting postgresql_command "psql")"
POSTGRESQL_HOST="$(cfg_get_setting postgresql_host "127.0.0.1")"
POSTGRESQL_PORT="$(cfg_get_setting postgresql_port "5432")"
POSTGRESQL_USER="$(cfg_get_setting postgresql_user "postgres")"
POSTGRESQL_DATABASE="$(cfg_get_setting postgresql_database "maxmind")"
POSTGRESQL_PASSWORD="$(cfg_get_setting postgresql_password "")"
POSTGRESQL_EXTRA_ARGS="$(cfg_get_setting postgresql_extra_args "")"
export MYSQL_COMMAND MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_EXTRA_ARGS MYSQL_ROUTINE_DEFINER
export POSTGRESQL_COMMAND POSTGRESQL_HOST POSTGRESQL_PORT POSTGRESQL_USER POSTGRESQL_DATABASE POSTGRESQL_PASSWORD POSTGRESQL_EXTRA_ARGS
export CONFIG_EDITION_ID CONFIG_EDITION_VENDOR CONFIG_EDITION_KIND CONFIG_PROJECT_NAME

OUTPUT_DIR_RAW="$(cfg_get_setting output_dir "../converted")"
OUTPUT_ARCHIVE_NAME="$(cfg_get_setting output_archive_name "")"
IP_VERSIONS_RAW="$(cfg_get convert ip_versions "4,6")"
LOCALES_RAW="$(cfg_get convert locales "en,ru,de,es,fr,ja,pt-BR,zh-CN")"
PRIORITY_FIELDS_RAW="$(cfg_get convert e_geoname_id_priority_columns "geoname_id,registered_country_geoname_id,represented_country_geoname_id")"
AUTO_DELETE_CSVS="$(bool_value "$(cfg_get_setting auto_delete_csvs "false")" false)"
SQL_BASH_GENERATOR_FILE_RAW="$(cfg_get convert sql_bash_generator_file "functions.bash")"

[[ -n "$SOURCE_ARCHIVE_URI" ]] || die "download.source_archive_uri is required"
if [[ "$SOURCE_ARCHIVE_URI" == *"\${license_key}"* && -z "$LICENSE_KEY" ]]; then
  die "download.license_key is empty, but source_archive_uri contains \${license_key}"
fi
validate_csv_values "$IP_VERSIONS_RAW" "4,6" "convert.ip_versions"
validate_csv_values "$LOCALES_RAW" "en,ru,de,es,fr,ja,pt-BR,zh-CN" "convert.locales"
validate_csv_values "$PRIORITY_FIELDS_RAW" "geoname_id,registered_country_geoname_id,represented_country_geoname_id" "convert.e_geoname_id_priority_columns"

SOURCE_ARCHIVE_URI="${SOURCE_ARCHIVE_URI//\$\{edition_id\}/$CONFIG_EDITION_ID}"
SOURCE_ARCHIVE_URI="${SOURCE_ARCHIVE_URI//\$\{license_key\}/$LICENSE_KEY}"
SOURCE_ARCHIVE_URI="${SOURCE_ARCHIVE_URI//\$\{database_type\}/$DBMS}"
SOURCE_ARCHIVE_URI="${SOURCE_ARCHIVE_URI//\$\{project_name\}/$CONFIG_PROJECT_NAME}"

OUTPUT_DIR="$(resolve_path "$OUTPUT_DIR_RAW" "$CONFIG_DIR")"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" >/dev/null 2>&1 && pwd -P)"

SELECTED_LOCALES=()
while IFS= read -r item; do
  [[ -n "$item" ]] && SELECTED_LOCALES+=("$item")
done < <(printf '%s\n' "$LOCALES_RAW" | split_config_list)

LOAD_LOCALES=("${SELECTED_LOCALES[@]}")
if ! array_contains "en" "${LOAD_LOCALES[@]}"; then
  LOAD_LOCALES=("en" "${LOAD_LOCALES[@]}")
fi

IP_VERSIONS=()
while IFS= read -r item; do
  [[ -n "$item" ]] && IP_VERSIONS+=("$item")
done < <(printf '%s\n' "$IP_VERSIONS_RAW" | split_config_list)

PRIORITY_FIELDS=()
while IFS= read -r item; do
  [[ -n "$item" ]] && PRIORITY_FIELDS+=("$item")
done < <(printf '%s\n' "$PRIORITY_FIELDS_RAW" | split_config_list)

ARCHIVE_PATH="$(debug_step "resolve/download archive" download_archive "$SOURCE_ARCHIVE_URI")"

ROOTS=()
declare -A ARCHIVE_MEMBERS=()
debug_begin DEBUG_ARCHIVE_SCAN_START_MS "scan archive members"
while IFS= read -r member; do
  ARCHIVE_MEMBERS[$member]=1
  root="${member%%/*}"
  if [[ "$root" =~ ^((GeoIP2|GeoLite2|GeoIP)-[A-Za-z0-9-]+-CSV)_([0-9]{8}|Example)$ ]]; then
    if ! array_contains "$root" "${ROOTS[@]:-}"; then
      ROOTS+=("$root")
    fi
  fi
done < <(unzip -Z1 "$ARCHIVE_PATH")
debug_end "scan archive members" "$DEBUG_ARCHIVE_SCAN_START_MS"

[[ "${#ROOTS[@]}" -gt 0 ]] || die "Cannot determine edition: ZIP root must look like GeoIP2-Domain-CSV_YYYYMMDD, GeoLite2-City-CSV_YYYYMMDD, or the same form with _Example"
[[ "${#ROOTS[@]}" -eq 1 ]] || die "Archive contains more than one MaxMind CSV root: ${ROOTS[*]}"

ARCHIVE_ROOT="${ROOTS[0]}"
[[ "$ARCHIVE_ROOT" =~ ^((GeoIP2|GeoLite2|GeoIP)-[A-Za-z0-9-]+-CSV)_([0-9]{8}|Example)$ ]] || die "Invalid archive root: $ARCHIVE_ROOT"
ARCHIVE_EDITION_ID="${BASH_REMATCH[1]}"
ARCHIVE_BUILD_DATE="${BASH_REMATCH[3]}"
ARCHIVE_EDITION_VENDOR="${ARCHIVE_EDITION_ID%%-*}"
ARCHIVE_EDITION_KIND="${ARCHIVE_EDITION_ID#$ARCHIVE_EDITION_VENDOR-}"
ARCHIVE_EDITION_KIND="${ARCHIVE_EDITION_KIND%-CSV}"
CSV_PREFIX="${ARCHIVE_EDITION_ID%-CSV}"
ARCHIVE_FAMILY="network"
case "$ARCHIVE_EDITION_KIND" in
  City|Country|Enterprise) ARCHIVE_FAMILY="location" ;;
esac
ARCHIVE_LOCATION_KIND="$ARCHIVE_EDITION_KIND"
[[ "$ARCHIVE_EDITION_KIND" == "Enterprise" ]] && ARCHIVE_LOCATION_KIND="City"
export ARCHIVE_ROOT ARCHIVE_EDITION_ID ARCHIVE_EDITION_VENDOR ARCHIVE_EDITION_KIND ARCHIVE_LOCATION_KIND ARCHIVE_FAMILY ARCHIVE_BUILD_DATE CSV_PREFIX

if [[ "$ARCHIVE_EDITION_ID" != "$CONFIG_EDITION_ID" ]]; then
  die "Archive edition is $ARCHIVE_EDITION_ID, but config expects $CONFIG_EDITION_ID"
fi

if [[ -z "$SCHEMA_NAME" ]]; then
  if [[ "$CONFIG_PROJECT_NAME" != "$ARCHIVE_EDITION_ID" && "$CONFIG_PROJECT_NAME" != "default" ]]; then
    SCHEMA_NAME="$CONFIG_PROJECT_NAME"
  else
    SCHEMA_NAME="maxmind_$(printf '%s' "${ARCHIVE_EDITION_KIND,,}" | tr '-' '_')"
  fi
fi

RUN_ID="l$(date +%y%m%d%H%M%S)_$$"
BUILD_RUN_ID="${MAXMIND_CSV2SQL_BUILD_RUN_ID:-b$(date -u +%Y%m%dT%H%M%SZ)_$$}"
export BUILD_RUN_ID
RUN_DIR="$OUTPUT_DIR/$CONFIG_PROJECT_NAME.$DBMS"
case "$RUN_DIR" in
  "$OUTPUT_DIR"/*) ;;
  *) die "Resolved output path is outside output_dir: $RUN_DIR" ;;
esac
if [[ "${MAXMIND_CSV2SQL_RESET_OUTPUT:-true}" == "true" ]]; then
  debug_step "reset output directory" rm -rf -- "$RUN_DIR"
fi
debug_step "create output directory" mkdir -p "$RUN_DIR"
CSV_DIR="$RUN_DIR/csv/$ARCHIVE_ROOT"
debug_step "create CSV output directory" mkdir -p "$CSV_DIR"

info "Archive: $ARCHIVE_PATH"
info "Edition: $ARCHIVE_EDITION_ID, build date: $ARCHIVE_BUILD_DATE, dbms: $DBMS, schema: $SCHEMA_NAME"
info "Output: $RUN_DIR"
info "CSV output: $CSV_DIR"

extract_member() {
  local filename="$1"
  local member="$ARCHIVE_ROOT/$filename"
  if [[ ! -v 'ARCHIVE_MEMBERS[$member]' ]]; then
    die "Archive does not contain required file: $member"
  fi
  debug_step "extract $filename" unzip -p "$ARCHIVE_PATH" "$member" > "$CSV_DIR/$filename"
}

for locale in "${LOAD_LOCALES[@]}"; do
  if [[ "$ARCHIVE_FAMILY" == "location" ]]; then
    extract_member "$CSV_PREFIX-Locations-$locale.csv"
  fi
done
for version in "${IP_VERSIONS[@]}"; do
  extract_member "$CSV_PREFIX-Blocks-IPv$version.csv"
done
ENTERPRISE_ISP_CSV=""
if [[ "$ARCHIVE_EDITION_KIND" == "Enterprise" ]]; then
  ENTERPRISE_ISP_CSV="$CSV_PREFIX-ISP.csv"
  extract_member "$ENTERPRISE_ISP_CSV"
fi

EMOJI_TSV="$CSV_DIR/$CSV_PREFIX-emoji.tsv"
debug_begin DEBUG_EMOJI_START_MS "prepare emoji TSV"
if [[ "$ARCHIVE_FAMILY" != "location" ]]; then
  : > "$EMOJI_TSV"
elif [[ -f "$CONFIG_DIR/emoji.txt" ]]; then
  awk 'NF >= 2 {
    sub(/\r$/, "", $2)
    if (tolower($1) == "default") print "\t" $2
    else if ($1 ~ /^[A-Za-z][A-Za-z]$/) print toupper($1) "\t" $2
  }' "$CONFIG_DIR/emoji.txt" > "$EMOJI_TSV"
elif [[ -f "$SCRIPT_DIR/configs/emoji.txt" ]]; then
  awk 'NF >= 2 {
    sub(/\r$/, "", $2)
    if (tolower($1) == "default") print "\t" $2
    else if ($1 ~ /^[A-Za-z][A-Za-z]$/) print toupper($1) "\t" $2
  }' "$SCRIPT_DIR/configs/emoji.txt" > "$EMOJI_TSV"
else
  : > "$EMOJI_TSV"
fi
debug_end "prepare emoji TSV" "$DEBUG_EMOJI_START_MS"

cache_header_columns() {
  local file="$1"
  local header value col
  local -a cols=()
  if [[ -v 'HEADER_COLUMNS_CACHE[$file]' ]]; then
    return
  fi
  IFS= read -r header < "$file" || header=""
  header="${header%$'\r'}"
  header="${header#$'\xef\xbb\xbf'}"
  value=""
  IFS=',' read -r -a cols <<< "$header"
  for col in "${cols[@]}"; do
    value+="${col}"$'\n'
  done
  value="${value%$'\n'}"
  HEADER_COLUMNS_CACHE[$file]="$value"
}

header_columns() {
  local file="$1"
  local value
  cache_header_columns "$file"
  value="${HEADER_COLUMNS_CACHE[$file]:-}"
  [[ -n "$value" ]] && printf '%s\n' "$value"
}

csv_has_column() {
  local file="$1"
  local wanted="$2"
  local col cache_key status
  cache_key="${file}"$'\034'"${wanted}"
  if [[ -v 'CSV_HAS_COLUMN_CACHE[$cache_key]' ]]; then
    return "${CSV_HAS_COLUMN_CACHE[$cache_key]}"
  fi
  while IFS= read -r col; do
    if [[ "$col" == "$wanted" ]]; then
      status=0
      CSV_HAS_COLUMN_CACHE[$cache_key]="$status"
      return "$status"
    fi
  done < <(header_columns "$file")
  status=1
  CSV_HAS_COLUMN_CACHE[$cache_key]="$status"
  return "$status"
}

debug_begin DEBUG_HEADER_START_MS "cache CSV headers"
for csv_file in "$CSV_DIR"/*.csv; do
  [[ -f "$csv_file" ]] && cache_header_columns "$csv_file"
done
debug_end "cache CSV headers" "$DEBUG_HEADER_START_MS"

validate_location_filter_columns() {
  local key value
  [[ "$ARCHIVE_FAMILY" == "location" ]] || return 0
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] || continue
    csv_has_column "$CSV_DIR/$CSV_PREFIX-Locations-en.csv" "$key" || die "location_filters.$key is not present in $CSV_PREFIX-Locations-en.csv"
  done < <(section_pairs location_filters)
}

debug_step "validate location filters" validate_location_filter_columns

load_sql_bash_generator() {
  local functions_file="$1"
  local fn
  [[ -f "$functions_file" ]] || die "SQL Bash generator file not found: $functions_file"
  # Project SQL Bash generator functions are trusted local project code.
  # shellcheck source=/dev/null
  source "$functions_file"
  for fn in \
    write_00_create_raw write_10_load_raw write_20_transform_stage write_90_indexes_stage \
    write_98_promote write_99_routines write_100_cleanup write_load_data write_loader make_output_archive; do
    declare -F "$fn" >/dev/null 2>&1 || die "SQL Bash generator file $functions_file does not define required function: $fn"
  done
}

resolve_sql_bash_generator_file() {
  local raw="$1"
  local resolved
  if [[ -z "$raw" ]]; then
    raw="functions.bash"
  fi
  raw="${raw//\$\{edition_id\}/$CONFIG_EDITION_ID}"
  raw="${raw//\$\{edition_kind\}/$CONFIG_EDITION_KIND}"
  raw="${raw//\$\{edition_vendor\}/$CONFIG_EDITION_VENDOR}"
  raw="${raw//\$\{database_type\}/$DBMS}"
  raw="${raw//\$\{project_name\}/$CONFIG_PROJECT_NAME}"
  if [[ "$raw" == "functions.bash" ]]; then
    for raw in \
      "../generators/${CONFIG_PROJECT_NAME}/functions.bash" \
      "$SCRIPT_DIR/generators/default/functions.bash"; do
      resolved="$(resolve_path "$raw" "$CONFIG_DIR")"
      if [[ -f "$resolved" ]]; then
        printf '%s\n' "$resolved"
        return
      fi
    done
  fi
  resolved="$(resolve_path "$raw" "$CONFIG_DIR")"
  if [[ -f "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return
  fi
  printf '%s\n' "$resolved"
}

SQL_BASH_GENERATOR_FILE="$(resolve_sql_bash_generator_file "$SQL_BASH_GENERATOR_FILE_RAW")"
info "SQL Bash generator: $SQL_BASH_GENERATOR_FILE"
debug_step "load SQL Bash generator" load_sql_bash_generator "$SQL_BASH_GENERATOR_FILE"
if declare -F validate_output_columns_config >/dev/null 2>&1; then
  debug_step "validate output column config" validate_output_columns_config
fi
START_SECONDS="$(date +%s)"
debug_step "write 00_create_raw.sql" write_00_create_raw
debug_step "write 10_load_raw.sql" write_10_load_raw
debug_step "write 20_transform_stage.sql" write_20_transform_stage
debug_step "write 90_indexes_stage.sql" write_90_indexes_stage
debug_step "write 98_promote.sql" write_98_promote
debug_step "write 99_routines.sql" write_99_routines
debug_step "write 100_cleanup_raw.sql" write_100_cleanup
debug_step "write load_data.sql" write_load_data
debug_step "write loader.sh" write_loader
debug_step "make output archive" make_output_archive "$OUTPUT_ARCHIVE_NAME"

if [[ "$AUTO_EXECUTE_LOADER_SH" == "true" ]]; then
  info "Executing generated loader"
  debug_step "execute generated loader" "$RUN_DIR/loader.sh"
else
  info "Execution is disabled by settings.auto_execute_loader_sh=false; generated loader: $RUN_DIR/loader.sh"
fi

if [[ "$AUTO_DELETE_CSVS" == "true" && "$AUTO_EXECUTE_LOADER_SH" == "true" ]]; then
  debug_step "delete extracted CSV files" find "$CSV_DIR" -maxdepth 1 -type f \( -name '*.csv' -o -name '*.tsv' \) -delete
fi

END_SECONDS="$(date +%s)"
ELAPSED=$((END_SECONDS - START_SECONDS))
info "Complete in $((ELAPSED / 60))m $((ELAPSED % 60))s"
debug_end "total $ARCHIVE_EDITION_ID" "$DEBUG_PROCESS_START_MS"
