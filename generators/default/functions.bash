# https://github.com/mbto/maxmind-csv2sql-converter v1.3
declare -g DBMS MYSQL_COMMAND MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_EXTRA_ARGS MYSQL_ROUTINE_DEFINER
declare -g POSTGRESQL_COMMAND POSTGRESQL_HOST POSTGRESQL_PORT POSTGRESQL_USER POSTGRESQL_DATABASE POSTGRESQL_PASSWORD POSTGRESQL_EXTRA_ARGS
declare -g CONVERTER_VERSION SCHEMA_VERSION BUILD_RUN_ID
: "${DBMS:?DBMS must be set before sourcing default generator functions}"

declare -gA CONFIGURED_COLUMN_ENABLED_CACHE=()
declare -gA COLUMN_ENABLED_CACHE=()
declare -gA FINAL_TABLE_ENABLED_CACHE=()
declare -gA BLOCK_TABLE_HAS_OUTPUT_COLUMN_CACHE=()
declare -ga ROUTINE_SELECT_NAMES_CACHE=()
declare -ga ROUTINE_SELECT_EXPRS_CACHE=()
declare -ga ROUTINE_SELECT_TYPES_CACHE=()
declare -g ROUTINE_SELECT_PARTS_CACHE_READY=false
declare -g NETWORK_LOOKUP_COLUMNS_CACHE_READY=false
declare -g NETWORK_LOOKUP_COLUMNS_CACHE=""

columns_csv_ident() {
  local dbms="$1"
  shift
  local first=true
  local col
  for col in "$@"; do
    if [[ "$first" == "true" ]]; then first=false; else printf ','; fi
    if [[ "$dbms" == "mysql" ]]; then mysql_ident "$col"; else pg_ident "$col"; fi
  done
}

join_sql_items() {
  local separator="$1"
  shift
  local first=true
  local item
  for item in "$@"; do
    if [[ "$first" == "true" ]]; then first=false; else printf '%s' "$separator"; fi
    printf '%s' "$item"
  done
}

column_config_key() {
  local table="$1"
  local column="$2"
  case "$column" in
    continent_name_*) printf 'continent_name' ;;
    name_*) printf 'name' ;;
    *) printf '%s' "$column" ;;
  esac
}

is_location_family() {
  [[ "${ARCHIVE_FAMILY:-location}" == "location" ]]
}

is_city_location() {
  [[ "${ARCHIVE_LOCATION_KIND:-$ARCHIVE_EDITION_KIND}" == "City" ]]
}

has_enterprise_isp() {
  [[ "$ARCHIVE_EDITION_KIND" == "Enterprise" && -n "${ENTERPRISE_ISP_CSV:-}" ]]
}

configured_column_enabled() {
  local table="$1"
  local column="$2"
  local key raw cache_key status
  case "$column" in
    continent_name_*) key="continent_name" ;;
    name_*) key="name" ;;
    *) key="$column" ;;
  esac
  cache_key="${table}"$'\034'"${key}"
  if [[ -v 'CONFIGURED_COLUMN_ENABLED_CACHE[$cache_key]' ]]; then
    return "${CONFIGURED_COLUMN_ENABLED_CACHE[$cache_key]}"
  fi
  raw="$(cfg_get "columns.$table" "$key" "true")"
  case "${raw,,}" in
    ""|1|true|yes|y|on) status=0 ;;
    0|false|no|n|off) status=1 ;;
    *) die "Invalid boolean value: $raw" ;;
  esac
  CONFIGURED_COLUMN_ENABLED_CACHE[$cache_key]="$status"
  return "$status"
}

any_configured_column_enabled() {
  local table="$1"
  shift
  local column
  for column in "$@"; do
    if configured_column_enabled "$table" "$column"; then
      return 0
    fi
  done
  return 1
}

geoname_role_columns() {
  printf '%s\n' geoname_id registered_country_geoname_id represented_country_geoname_id
}

any_block_output_column_enabled() {
  local column="$1"
  local version
  for version in "${IP_VERSIONS[@]}"; do
    if column_enabled "ipv$version" "$column"; then
      return 0
    fi
  done
  return 1
}

enabled_geoname_role_columns() {
  local column
  while IFS= read -r column; do
    any_block_output_column_enabled "$column" && printf '%s\n' "$column"
  done < <(geoname_role_columns)
}

isp_table_enabled() {
  local col
  has_enterprise_isp || return 1
  while IFS= read -r col; do
    [[ -n "$col" && "$col" != "isp_id" ]] || continue
    if configured_column_enabled isp "$col"; then
      return 0
    fi
  done < <(header_columns "$CSV_DIR/$ENTERPRISE_ISP_CSV")
  return 1
}

final_table_enabled() {
  local table="$1"
  local status=1
  if [[ -v 'FINAL_TABLE_ENABLED_CACHE[$table]' ]]; then
    return "${FINAL_TABLE_ENABLED_CACHE[$table]}"
  fi
  case "$table" in
    dataset_metadata)
      status=0
      ;;
    timezone)
      if is_city_location && configured_column_enabled timezone name; then
        status=0
      fi
      ;;
    subdivision1|subdivision2)
      if is_city_location && any_configured_column_enabled "$table" iso_code name; then
        status=0
      fi
      ;;
    country)
      if ! is_location_family; then
        status=1
      elif is_city_location; then
        if any_configured_column_enabled country continent_code continent_name iso_code emoji name; then
          status=0
        fi
      else
        status=0
      fi
      ;;
    city)
      if is_location_family && is_city_location; then
        status=0
      fi
      ;;
    isp)
      if isp_table_enabled; then
        status=0
      fi
      ;;
    ipv4|ipv6)
      if array_contains "${table#ipv}" "${IP_VERSIONS[@]}"; then
        status=0
      fi
      ;;
    *)
      status=1
      ;;
  esac
  FINAL_TABLE_ENABLED_CACHE[$table]="$status"
  return "$status"
}

column_enabled() {
  local table="$1"
  local column="$2"
  local cache_key status=1
  cache_key="${table}"$'\034'"${column}"
  if [[ -v 'COLUMN_ENABLED_CACHE[$cache_key]' ]]; then
    return "${COLUMN_ENABLED_CACHE[$cache_key]}"
  fi
  if ! configured_column_enabled "$table" "$column"; then
    COLUMN_ENABLED_CACHE[$cache_key]=1
    return 1
  fi
  case "$table:$column" in
    city:country_id)
      if final_table_enabled country; then status=0; fi
      ;;
    city:subdivision1_id)
      if final_table_enabled subdivision1; then status=0; fi
      ;;
    city:subdivision2_id)
      if final_table_enabled subdivision2; then status=0; fi
      ;;
    city:time_zone_id)
      if final_table_enabled timezone; then status=0; fi
      ;;
    *)
      status=0
      ;;
  esac
  COLUMN_ENABLED_CACHE[$cache_key]="$status"
  return "$status"
}

require_column_enabled() {
  local table="$1"
  local column="$2"
  if ! column_enabled "$table" "$column"; then
    die "columns.$table.$(column_config_key "$table" "$column") is required by the default SQL generator"
  fi
}

egeo_check_expr() {
  local table="$1"
  local e_col source_col role code branch
  local branches=()
  e_col="$(ident e_geoname_id)"
  source_col="$(ident e_geoname_source_code)"
  while IFS= read -r role; do
    code="$(geoname_source_code "$role")"
    branch="($source_col = $code"
    if column_enabled "$table" "$role"; then
      branch+=" AND $(ident "$role") IS NOT NULL AND $e_col = $(ident "$role")"
    fi
    branch+=")"
    branches+=("$branch")
  done < <(geoname_role_columns)
  printf '((%s IS NULL AND %s IS NULL) OR (%s IS NOT NULL AND %s IS NOT NULL AND (%s)))' \
    "$e_col" "$source_col" "$e_col" "$source_col" "$(join_sql_items ' OR ' "${branches[@]}")"
}

validate_column_config_section() {
  local table="$1"
  local allowed="$2"
  local key value
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] || continue
    case ",$allowed," in
      *,"$key",*) ;;
      *) die "Unsupported columns.$table key: $key" ;;
    esac
    bool_value "$value" true >/dev/null
  done < <(section_pairs "columns.$table")
}

validate_output_columns_config() {
  local table version ip_range_columns allowed col
  ip_range_columns="start_ip,last_ip"

  if ! is_location_family; then
    validate_column_config_section country ""
    validate_column_config_section subdivision1 ""
    validate_column_config_section subdivision2 ""
    validate_column_config_section city ""
    validate_column_config_section timezone ""
    validate_column_config_section isp ""
    for version in "${IP_VERSIONS[@]}"; do
      table="ipv$version"
      allowed="network,$ip_range_columns"
      while IFS= read -r col; do
        [[ -n "$col" && "$col" != "network" ]] && allowed="${allowed},$col"
      done < <(header_columns "$CSV_DIR/$CSV_PREFIX-Blocks-IPv$version.csv")
      validate_column_config_section "$table" "$allowed"
      require_column_enabled "$table" network
      require_column_enabled "$table" start_ip
      require_column_enabled "$table" last_ip
    done
    return
  fi

  if is_city_location; then
    validate_column_config_section country "id,continent_code,continent_name,iso_code,emoji,name"
    validate_column_config_section subdivision1 "id,iso_code,name"
    validate_column_config_section subdivision2 "id,iso_code,name"
    validate_column_config_section city "geoname_id,country_id,subdivision1_id,subdivision2_id,name,metro_code,time_zone_id,is_in_european_union"
    validate_column_config_section timezone "id,name"
  else
    validate_column_config_section country "geoname_id,continent_code,continent_name,iso_code,emoji,name,is_in_european_union"
    validate_column_config_section subdivision1 ""
    validate_column_config_section subdivision2 ""
    validate_column_config_section city ""
    validate_column_config_section timezone ""
  fi
  if has_enterprise_isp; then
    allowed=""
    while IFS= read -r col; do
      [[ -n "$col" ]] && allowed="${allowed}${allowed:+,}$col"
    done < <(header_columns "$CSV_DIR/$ENTERPRISE_ISP_CSV")
    validate_column_config_section isp "$allowed"
    require_column_enabled isp isp_id
  else
    validate_column_config_section isp ""
  fi
  for version in "${IP_VERSIONS[@]}"; do
    table="ipv$version"
    allowed="network,$ip_range_columns,e_geoname_id,e_geoname_source_code"
    while IFS= read -r col; do
      [[ -n "$col" && "$col" != "network" ]] && allowed="${allowed},$col"
    done < <(header_columns "$CSV_DIR/$CSV_PREFIX-Blocks-IPv$version.csv")
    validate_column_config_section "$table" "$allowed"
  done

  if is_city_location; then
    require_column_enabled city geoname_id
    final_table_enabled country && require_column_enabled country id
    final_table_enabled subdivision1 && require_column_enabled subdivision1 id
    final_table_enabled subdivision2 && require_column_enabled subdivision2 id
    final_table_enabled timezone && require_column_enabled timezone id
  else
    require_column_enabled country geoname_id
  fi

  for version in "${IP_VERSIONS[@]}"; do
    table="ipv$version"
    require_column_enabled "$table" network
    require_column_enabled "$table" e_geoname_id
    require_column_enabled "$table" e_geoname_source_code
    require_column_enabled "$table" start_ip
    require_column_enabled "$table" last_ip
  done
}

append_if_column_enabled() {
  local -n __target_ref="$1"
  local table="$2"
  local column="$3"
  local value="$4"
  if column_enabled "$table" "$column"; then
    __target_ref+=("$value")
  fi
}

append_column_select_if_enabled() {
  local -n __cols_ref="$1"
  local -n __selects_ref="$2"
  local table="$3"
  local column="$4"
  local output_column="$5"
  local select_expr="$6"
  if column_enabled "$table" "$column"; then
    __cols_ref+=("$output_column")
    __selects_ref+=("$select_expr")
  fi
}

emit_create_table_sql() {
  local q="$1"
  shift
  local lines=("$@")
  local suffix=";"
  local i comma
  [[ "$DBMS" == "mysql" ]] && suffix=" ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"
  echo "CREATE TABLE $q ("
  for ((i = 0; i < ${#lines[@]}; i++)); do
    comma=","
    (( i == ${#lines[@]} - 1 )) && comma=""
    printf "%s%s\n" "${lines[i]}" "$comma"
  done
  printf ")%s\n\n" "$suffix"
}

sql_file_append_mode() {
  [[ "${MAXMIND_CSV2SQL_APPEND_OUTPUT:-false}" == "true" ]]
}

start_sql_file() {
  local file="$1"
  local title="$2"
  if ! sql_file_append_mode || [[ ! -f "$file" ]]; then
    : > "$file"
    echo "-- $title" >> "$file"
  else
    echo >> "$file"
  fi
  echo "-- $ARCHIVE_EDITION_ID build $ARCHIVE_BUILD_DATE" >> "$file"
  if [[ "$DBMS" == "mysql" ]]; then
    echo "CREATE SCHEMA IF NOT EXISTS $(mysql_ident "$SCHEMA_NAME") DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >> "$file"
    echo "USE $(mysql_ident "$SCHEMA_NAME");" >> "$file"
  else
    echo "CREATE SCHEMA IF NOT EXISTS $(pg_ident "$SCHEMA_NAME");" >> "$file"
    echo "SET search_path TO $(pg_ident "$SCHEMA_NAME");" >> "$file"
  fi
  echo >> "$file"
}

pg_routine_search_path_clause() {
  printf 'SET search_path TO %s' "$(pg_ident "$SCHEMA_NAME")"
}

mysql_start_dml_transaction() {
  local file="$1"
  local label="${2:-DML batch}"
  [[ "$DBMS" == "mysql" ]] || return 0
  printf '%s\n' "-- $label. DDL outside this block performs implicit commits in MySQL." >> "$file"
  echo "START TRANSACTION;" >> "$file"
}

mysql_commit_dml_transaction() {
  local file="$1"
  [[ "$DBMS" == "mysql" ]] || return 0
  echo "COMMIT;" >> "$file"
  echo >> "$file"
}

mysql_load_data_sql() {
  local table="$1"
  local file="$2"
  shift 2
  local columns=("$@")
  local client_file vars="" col first
  client_file="$(to_client_path "$file")"
  for col in "${columns[@]}"; do
    vars="${vars}${vars:+,}@${col}"
  done
  {
    printf "LOAD DATA LOCAL INFILE %s\n" "$(sql_literal "$client_file")"
    printf "INTO TABLE %s\n" "$(mysql_ident "$table")"
    printf "CHARACTER SET utf8mb4\n"
    printf "FIELDS TERMINATED BY ',' ENCLOSED BY '\"' ESCAPED BY '\"'\n"
    printf '%s\n' "LINES TERMINATED BY '\n'"
    printf "IGNORE 1 LINES\n"
    printf "(%s)\n" "$vars"
    printf "SET\n"
    first=true
    for col in "${columns[@]}"; do
      if [[ "$first" == "true" ]]; then
        first=false
        printf "  "
      else
        printf ",\n  "
      fi
      printf "%s = NULLIF(TRIM(TRAILING CHAR(13) FROM @%s), '')" "$(mysql_ident "$col")" "$col"
    done
    printf ";\n\n"
  }
}

pg_copy_sql() {
  local table="$1"
  local file="$2"
  shift 2
  local columns=("$@")
  local client_file
  client_file="$(to_client_path "$file")"
  printf "\\copy %s (%s) FROM %s WITH (FORMAT csv, HEADER true);\n\n" \
    "$(pg_ident "$table")" "$(columns_csv_ident postgresql "${columns[@]}")" "$(sql_literal "$client_file")"
}

mysql_type_location() {
  local col="$1"
  case "$col" in
    geoname_id) echo "INT UNSIGNED DEFAULT NULL" ;;
    locale_code) echo "VARCHAR(16) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL" ;;
    continent_code|country_iso_code) echo "CHAR(2) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL" ;;
    subdivision_1_iso_code|subdivision_2_iso_code) echo "VARCHAR(3) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL" ;;
    metro_code) echo "INT UNSIGNED DEFAULT NULL" ;;
    is_in_european_union) echo "TINYINT(1) UNSIGNED DEFAULT NULL" ;;
    time_zone) echo "VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL" ;;
    *) echo "TEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL" ;;
  esac
}

pg_type_location() {
  local col="$1"
  case "$col" in
    geoname_id|metro_code) echo "integer DEFAULT NULL" ;;
    locale_code) echo "varchar(16) DEFAULT NULL" ;;
    continent_code|country_iso_code) echo "char(2) DEFAULT NULL" ;;
    subdivision_1_iso_code|subdivision_2_iso_code) echo "varchar(3) DEFAULT NULL" ;;
    is_in_european_union) echo "boolean DEFAULT NULL" ;;
    time_zone) echo "varchar(64) DEFAULT NULL" ;;
    *) echo "text DEFAULT NULL" ;;
  esac
}

mysql_type_block() {
  local col="$1"
  case "$col" in
    network) echo "VARCHAR(43) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL" ;;
    e_geoname_id|geoname_id|registered_country_geoname_id|represented_country_geoname_id|accuracy_radius|autonomous_system_number|isp_id|anonymizer_confidence|ipv4_24|ipv4_32|ipv6_32|ipv6_48|ipv6_64) echo "INT UNSIGNED DEFAULT NULL" ;;
    e_geoname_source_code) echo "TINYINT UNSIGNED DEFAULT NULL" ;;
    is_anonymous_proxy|is_satellite_provider|is_anycast|is_anonymous|is_anonymous_vpn|is_hosting_provider|is_public_proxy|is_tor_exit_node|is_residential_proxy|is_legitimate_proxy) echo "TINYINT(1) UNSIGNED DEFAULT NULL" ;;
    postal_code) echo "VARCHAR(16) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL" ;;
    latitude) echo "DECIMAL(6,4) DEFAULT NULL" ;;
    longitude) echo "DECIMAL(7,4) DEFAULT NULL" ;;
    country_confidence|subdivision_confidence|city_confidence|postal_confidence) echo "DECIMAL(7,4) DEFAULT NULL" ;;
    ip_risk|score|static_ip_score) echo "DECIMAL(4,2) DEFAULT NULL" ;;
    network_last_seen) echo "DATE DEFAULT NULL" ;;
    connection_type|user_type|mobile_country_code|mobile_network_code) echo "VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL" ;;
    *) echo "TEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL" ;;
  esac
}

mysql_network_type_for_table() {
  case "$1" in
    *ipv4*|ipv4) echo "VARCHAR(18) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" ;;
    *) echo "VARCHAR(43) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" ;;
  esac
}

pg_type_block() {
  local col="$1"
  case "$col" in
    network) echo "text DEFAULT NULL" ;;
    e_geoname_id|geoname_id|registered_country_geoname_id|represented_country_geoname_id|accuracy_radius|autonomous_system_number|isp_id|anonymizer_confidence|ipv4_24|ipv4_32|ipv6_32|ipv6_48|ipv6_64) echo "integer DEFAULT NULL" ;;
    e_geoname_source_code) echo "smallint DEFAULT NULL" ;;
    is_anonymous_proxy|is_satellite_provider|is_anycast|is_anonymous|is_anonymous_vpn|is_hosting_provider|is_public_proxy|is_tor_exit_node|is_residential_proxy|is_legitimate_proxy) echo "boolean DEFAULT NULL" ;;
    postal_code) echo "varchar(16) DEFAULT NULL" ;;
    latitude) echo "numeric(6,4) DEFAULT NULL" ;;
    longitude) echo "numeric(7,4) DEFAULT NULL" ;;
    country_confidence|subdivision_confidence|city_confidence|postal_confidence) echo "numeric(7,4) DEFAULT NULL" ;;
    ip_risk|score|static_ip_score) echo "numeric(4,2) DEFAULT NULL" ;;
    network_last_seen) echo "date DEFAULT NULL" ;;
    connection_type|user_type|mobile_country_code|mobile_network_code) echo "varchar(64) DEFAULT NULL" ;;
    *) echo "text DEFAULT NULL" ;;
  esac
}

block_csv_path() {
  local table="$1"
  local version="${table#ipv}"
  printf '%s/%s-Blocks-IPv%s.csv' "$CSV_DIR" "$CSV_PREFIX" "$version"
}

append_block_header_columns() {
  local -n lines_ref="$1"
  local table="$2"
  shift 2
  local skip=("$@")
  local csv col
  csv="$(block_csv_path "$table")"
  while IFS= read -r col; do
    [[ -n "$col" ]] || continue
    array_contains "$col" "${skip[@]}" && continue
    if column_enabled "$table" "$col"; then
      if [[ "$DBMS" == "mysql" ]]; then
        lines_ref+=("  $(mysql_ident "$col") $(mysql_type_block "$col")")
      else
        lines_ref+=("  $(pg_ident "$col") $(pg_type_block "$col")")
      fi
    fi
  done < <(header_columns "$csv")
}

append_block_header_selects() {
  local -n cols_ref="$1"
  local -n selects_ref="$2"
  local table="$3"
  local source_alias="$4"
  shift 4
  local skip=("$@")
  local csv col
  csv="$(block_csv_path "$table")"
  while IFS= read -r col; do
    [[ -n "$col" ]] || continue
    array_contains "$col" "${skip[@]}" && continue
    if column_enabled "$table" "$col"; then
      cols_ref+=("$col")
      selects_ref+=("$source_alias.$(ident "$col")")
    fi
  done < <(header_columns "$csv")
}

append_isp_header_columns() {
  local -n lines_ref="$1"
  local col
  while IFS= read -r col; do
    [[ -n "$col" && "$col" != "isp_id" ]] || continue
    if column_enabled isp "$col"; then
      if [[ "$DBMS" == "mysql" ]]; then
        lines_ref+=("  $(mysql_ident "$col") $(mysql_type_block "$col")")
      else
        lines_ref+=("  $(pg_ident "$col") $(pg_type_block "$col")")
      fi
    fi
  done < <(header_columns "$CSV_DIR/$ENTERPRISE_ISP_CSV")
}

create_raw_location_sql() {
  local table="$1"
  local csv="$2"
  local q col first
  q="$(ident "$table")"
  echo "CREATE TABLE $q ("
  first=true
  while IFS= read -r col; do
    if [[ "$first" == "true" ]]; then first=false; else echo ","; fi
    if [[ "$DBMS" == "mysql" ]]; then
      printf "  %s %s" "$(mysql_ident "$col")" "$(mysql_type_location "$col")"
    else
      printf "  %s %s" "$(pg_ident "$col")" "$(pg_type_location "$col")"
    fi
  done < <(header_columns "$csv")
  if [[ "$DBMS" == "mysql" ]]; then
    printf "\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;\n\n"
  else
    printf "\n);\n\n"
  fi
}

create_raw_blocks_sql() {
  local table="$1"
  local csv="$2"
  local q col first
  q="$(ident "$table")"
  echo "CREATE TABLE $q ("
  first=true
  while IFS= read -r col; do
    if [[ "$first" == "true" ]]; then first=false; else echo ","; fi
    if [[ "$DBMS" == "mysql" ]]; then
      if [[ "$col" == "network" ]]; then
        printf "  %s %s DEFAULT NULL" "$(mysql_ident "$col")" "$(mysql_network_type_for_table "$table")"
      else
        printf "  %s %s" "$(mysql_ident "$col")" "$(mysql_type_block "$col")"
      fi
    else
      printf "  %s %s" "$(pg_ident "$col")" "$(pg_type_block "$col")"
    fi
  done < <(header_columns "$csv")
  if [[ "$DBMS" == "mysql" ]]; then
    printf "\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;\n\n"
  else
    printf "\n);\n\n"
  fi
}

raw_isp_table() {
  printf 'raw_isp__load_%s' "$RUN_ID"
}

create_raw_isp_sql() {
  local table="$1"
  local csv="$2"
  local q col first
  q="$(ident "$table")"
  echo "CREATE TABLE $q ("
  first=true
  while IFS= read -r col; do
    if [[ "$first" == "true" ]]; then first=false; else echo ","; fi
    if [[ "$DBMS" == "mysql" ]]; then
      printf "  %s %s" "$(mysql_ident "$col")" "$(mysql_type_block "$col")"
    else
      printf "  %s %s" "$(pg_ident "$col")" "$(pg_type_block "$col")"
    fi
  done < <(header_columns "$csv")
  if [[ "$DBMS" == "mysql" ]]; then
    printf "\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;\n\n"
  else
    printf "\n);\n\n"
  fi
}

stage_name() {
  printf '%s__load_%s' "$1" "$RUN_ID"
}

helper_name() {
  printf '%s__load_%s' "$1" "$RUN_ID"
}

final_table_order() {
  printf '%s\n' dataset_metadata
  if is_location_family; then
    if is_city_location; then
      final_table_enabled timezone && printf '%s\n' timezone
      final_table_enabled country && printf '%s\n' country
      final_table_enabled subdivision1 && printf '%s\n' subdivision1
      final_table_enabled subdivision2 && printf '%s\n' subdivision2
      printf '%s\n' city
      final_table_enabled isp && printf '%s\n' isp
    else
      printf '%s\n' country
    fi
  fi
  for version in "${IP_VERSIONS[@]}"; do
    printf 'ipv%s\n' "$version"
  done
}

final_table_order_reversed() {
  local tables=()
  local table i
  while IFS= read -r table; do
    tables+=("$table")
  done < <(final_table_order)
  for ((i=${#tables[@]} - 1; i >= 0; i--)); do
    printf '%s\n' "${tables[i]}"
  done
}

write_table_ddl() {
  local file="$1"
  local table="$2"
  local q lines range_type
  q="$(ident "$(stage_name "$table")")"
  {
    case "$DBMS:$table" in
      mysql:dataset_metadata)
        lines=(
          "  $(mysql_ident run_id) VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL"
          "  $(mysql_ident edition_id) VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL"
          "  $(mysql_ident archive_root) VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL"
          "  $(mysql_ident source_build_date) DATE DEFAULT NULL"
          "  $(mysql_ident imported_at) DATETIME(6) NOT NULL"
          "  $(mysql_ident converter_version) VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL"
          "  $(mysql_ident schema_version) INT UNSIGNED NOT NULL"
          "  $(mysql_ident dbms) VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL"
          "  $(mysql_ident project_name) VARCHAR(128) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL"
          "  $(mysql_ident schema_name) VARCHAR(128) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL"
          "  $(mysql_ident ip_versions) JSON NOT NULL"
          "  $(mysql_ident selected_locales) JSON NOT NULL"
          "  $(mysql_ident loaded_locales) JSON NOT NULL"
          "  $(mysql_ident e_geoname_id_priority_columns) JSON NOT NULL"
          "  PRIMARY KEY ($(mysql_ident run_id))"
        )
        emit_create_table_sql "$q" "${lines[@]}"
        ;;
      postgresql:dataset_metadata)
        lines=(
          "  $(pg_ident run_id) varchar(64) NOT NULL"
          "  $(pg_ident edition_id) varchar(64) NOT NULL"
          "  $(pg_ident archive_root) varchar(255) NOT NULL"
          "  $(pg_ident source_build_date) date DEFAULT NULL"
          "  $(pg_ident imported_at) timestamptz NOT NULL"
          "  $(pg_ident converter_version) varchar(32) NOT NULL"
          "  $(pg_ident schema_version) integer NOT NULL"
          "  $(pg_ident dbms) varchar(16) NOT NULL"
          "  $(pg_ident project_name) varchar(128) NOT NULL"
          "  $(pg_ident schema_name) varchar(128) NOT NULL"
          "  $(pg_ident ip_versions) jsonb NOT NULL"
          "  $(pg_ident selected_locales) jsonb NOT NULL"
          "  $(pg_ident loaded_locales) jsonb NOT NULL"
          "  $(pg_ident e_geoname_id_priority_columns) jsonb NOT NULL"
          "  PRIMARY KEY ($(pg_ident run_id))"
        )
        emit_create_table_sql "$q" "${lines[@]}"
        ;;
      mysql:timezone)
        lines=()
        lines+=("  $(mysql_ident id) SMALLINT UNSIGNED NOT NULL")
        append_if_column_enabled lines timezone name "  $(mysql_ident name) VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL"
        lines+=("  PRIMARY KEY ($(mysql_ident id))")
        emit_create_table_sql "$q" "${lines[@]}"
        ;;
      postgresql:timezone)
        lines=()
        lines+=("  $(pg_ident id) smallint NOT NULL")
        append_if_column_enabled lines timezone name "  $(pg_ident name) varchar(64) NOT NULL"
        lines+=("  PRIMARY KEY ($(pg_ident id))")
        emit_create_table_sql "$q" "${lines[@]}"
        ;;
      mysql:country)
        lines=()
        if is_city_location; then
          lines+=("  $(mysql_ident id) SMALLINT UNSIGNED NOT NULL")
        else
          lines+=("  $(mysql_ident geoname_id) INT UNSIGNED NOT NULL")
        fi
        append_if_column_enabled lines country continent_code "  $(mysql_ident continent_code) CHAR(2) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL"
        for locale in "${SELECTED_LOCALES[@]}"; do
          append_if_column_enabled lines country "continent_name_$locale" "  $(mysql_ident "continent_name_$locale") VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL"
        done
        append_if_column_enabled lines country iso_code "  $(mysql_ident iso_code) CHAR(2) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL"
        append_if_column_enabled lines country emoji "  $(mysql_ident emoji) CHAR(2) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL"
        for locale in "${SELECTED_LOCALES[@]}"; do
          append_if_column_enabled lines country "name_$locale" "  $(mysql_ident "name_$locale") VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL"
        done
        if ! is_city_location; then
          append_if_column_enabled lines country is_in_european_union "  $(mysql_ident is_in_european_union) TINYINT(1) UNSIGNED NOT NULL"
          lines+=("  PRIMARY KEY ($(mysql_ident geoname_id))")
        else
          lines+=("  PRIMARY KEY ($(mysql_ident id))")
        fi
        emit_create_table_sql "$q" "${lines[@]}"
        ;;
      postgresql:country)
        lines=()
        if is_city_location; then
          lines+=("  $(pg_ident id) smallint NOT NULL")
        else
          lines+=("  $(pg_ident geoname_id) integer NOT NULL")
        fi
        append_if_column_enabled lines country continent_code "  $(pg_ident continent_code) char(2) DEFAULT NULL"
        for locale in "${SELECTED_LOCALES[@]}"; do
          append_if_column_enabled lines country "continent_name_$locale" "  $(pg_ident "continent_name_$locale") varchar(64) DEFAULT NULL"
        done
        append_if_column_enabled lines country iso_code "  $(pg_ident iso_code) char(2) DEFAULT NULL"
        append_if_column_enabled lines country emoji "  $(pg_ident emoji) char(2) DEFAULT NULL"
        for locale in "${SELECTED_LOCALES[@]}"; do
          append_if_column_enabled lines country "name_$locale" "  $(pg_ident "name_$locale") varchar(255) DEFAULT NULL"
        done
        if ! is_city_location; then
          append_if_column_enabled lines country is_in_european_union "  $(pg_ident is_in_european_union) boolean NOT NULL"
          lines+=("  PRIMARY KEY ($(pg_ident geoname_id))")
        else
          lines+=("  PRIMARY KEY ($(pg_ident id))")
        fi
        emit_create_table_sql "$q" "${lines[@]}"
        ;;
      mysql:subdivision1|mysql:subdivision2)
        lines=()
        lines+=("  $(mysql_ident id) SMALLINT UNSIGNED NOT NULL")
        append_if_column_enabled lines "$table" iso_code "  $(mysql_ident iso_code) VARCHAR(3) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL"
        for locale in "${SELECTED_LOCALES[@]}"; do
          append_if_column_enabled lines "$table" "name_$locale" "  $(mysql_ident "name_$locale") VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL"
        done
        lines+=("  PRIMARY KEY ($(mysql_ident id))")
        emit_create_table_sql "$q" "${lines[@]}"
        ;;
      postgresql:subdivision1|postgresql:subdivision2)
        lines=()
        lines+=("  $(pg_ident id) smallint NOT NULL")
        append_if_column_enabled lines "$table" iso_code "  $(pg_ident iso_code) varchar(3) NOT NULL"
        for locale in "${SELECTED_LOCALES[@]}"; do
          append_if_column_enabled lines "$table" "name_$locale" "  $(pg_ident "name_$locale") varchar(255) DEFAULT NULL"
        done
        lines+=("  PRIMARY KEY ($(pg_ident id))")
        emit_create_table_sql "$q" "${lines[@]}"
        ;;
      mysql:city)
        lines=()
        lines+=("  $(mysql_ident geoname_id) INT UNSIGNED NOT NULL")
        append_if_column_enabled lines city country_id "  $(mysql_ident country_id) SMALLINT UNSIGNED NOT NULL"
        append_if_column_enabled lines city subdivision1_id "  $(mysql_ident subdivision1_id) SMALLINT UNSIGNED DEFAULT NULL"
        append_if_column_enabled lines city subdivision2_id "  $(mysql_ident subdivision2_id) SMALLINT UNSIGNED DEFAULT NULL"
        for locale in "${SELECTED_LOCALES[@]}"; do
          append_if_column_enabled lines city "name_$locale" "  $(mysql_ident "name_$locale") VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL"
        done
        append_if_column_enabled lines city metro_code "  $(mysql_ident metro_code) SMALLINT UNSIGNED DEFAULT NULL"
        append_if_column_enabled lines city time_zone_id "  $(mysql_ident time_zone_id) SMALLINT UNSIGNED DEFAULT NULL"
        append_if_column_enabled lines city is_in_european_union "  $(mysql_ident is_in_european_union) TINYINT(1) UNSIGNED NOT NULL"
        lines+=("  PRIMARY KEY ($(mysql_ident geoname_id))")
        emit_create_table_sql "$q" "${lines[@]}"
        ;;
      postgresql:city)
        lines=()
        lines+=("  $(pg_ident geoname_id) integer NOT NULL")
        append_if_column_enabled lines city country_id "  $(pg_ident country_id) smallint NOT NULL"
        append_if_column_enabled lines city subdivision1_id "  $(pg_ident subdivision1_id) smallint DEFAULT NULL"
        append_if_column_enabled lines city subdivision2_id "  $(pg_ident subdivision2_id) smallint DEFAULT NULL"
        for locale in "${SELECTED_LOCALES[@]}"; do
          append_if_column_enabled lines city "name_$locale" "  $(pg_ident "name_$locale") varchar(255) DEFAULT NULL"
        done
        append_if_column_enabled lines city metro_code "  $(pg_ident metro_code) smallint DEFAULT NULL"
        append_if_column_enabled lines city time_zone_id "  $(pg_ident time_zone_id) smallint DEFAULT NULL"
        append_if_column_enabled lines city is_in_european_union "  $(pg_ident is_in_european_union) boolean NOT NULL"
        lines+=("  PRIMARY KEY ($(pg_ident geoname_id))")
        emit_create_table_sql "$q" "${lines[@]}"
        ;;
      mysql:isp)
        lines=()
        lines+=("  $(mysql_ident isp_id) INT UNSIGNED NOT NULL")
        append_isp_header_columns lines
        lines+=("  PRIMARY KEY ($(mysql_ident isp_id))")
        emit_create_table_sql "$q" "${lines[@]}"
        ;;
      postgresql:isp)
        lines=()
        lines+=("  $(pg_ident isp_id) integer NOT NULL")
        append_isp_header_columns lines
        lines+=("  PRIMARY KEY ($(pg_ident isp_id))")
        emit_create_table_sql "$q" "${lines[@]}"
        ;;
      mysql:ipv4|mysql:ipv6)
        if [[ "$table" == "ipv4" ]]; then range_type="INT UNSIGNED"; else range_type="DECIMAL(39,0) UNSIGNED"; fi
        lines=()
        lines+=("  $(mysql_ident network) $(mysql_network_type_for_table "$table") NOT NULL")
        lines+=("  $(mysql_ident start_ip) $range_type NOT NULL")
        lines+=("  $(mysql_ident last_ip) $range_type NOT NULL")
        if is_location_family; then
          lines+=("  $(mysql_ident e_geoname_id) INT UNSIGNED DEFAULT NULL COMMENT 'Effective GeoName ID selected from configured priority columns; NULL when no configured source resolves; see e_geoname_source_code and dataset_metadata'")
          lines+=("  $(mysql_ident e_geoname_source_code) TINYINT UNSIGNED DEFAULT NULL COMMENT 'Effective GeoName source: 1=geoname_id, 2=registered_country_geoname_id, 3=represented_country_geoname_id; NULL with e_geoname_id'")
        fi
        append_block_header_columns lines "$table" network
        if is_location_family; then
          lines+=("  CONSTRAINT $(mysql_ident "ck_${RUN_ID}_${table}_egeo") CHECK ($(egeo_check_expr "$table"))")
        fi
        lines+=("  PRIMARY KEY ($(mysql_ident network))")
        emit_create_table_sql "$q" "${lines[@]}"
        ;;
      postgresql:ipv4|postgresql:ipv6)
        lines=()
        lines+=("  $(pg_ident network) cidr NOT NULL")
        lines+=("  $(pg_ident start_ip) inet NOT NULL")
        lines+=("  $(pg_ident last_ip) inet NOT NULL")
        if is_location_family; then
          lines+=("  $(pg_ident e_geoname_id) integer DEFAULT NULL")
          lines+=("  $(pg_ident e_geoname_source_code) smallint DEFAULT NULL")
        fi
        append_block_header_columns lines "$table" network
        if is_location_family; then
          lines+=("  CONSTRAINT $(pg_ident "ck_${RUN_ID}_${table}_egeo") CHECK ($(egeo_check_expr "$table"))")
        fi
        lines+=("  PRIMARY KEY ($(pg_ident network))")
        emit_create_table_sql "$q" "${lines[@]}"
        if is_location_family; then
          echo "COMMENT ON COLUMN $q.$(pg_ident e_geoname_id) IS 'Effective GeoName ID selected from configured priority columns; NULL when no configured source resolves; see e_geoname_source_code and dataset_metadata';"
          echo "COMMENT ON COLUMN $q.$(pg_ident e_geoname_source_code) IS 'Effective GeoName source: 1=geoname_id, 2=registered_country_geoname_id, 3=represented_country_geoname_id; NULL with e_geoname_id';"
        fi
        ;;
    esac
  } >> "$file"
}

loc_alias() {
  printf 'l_%s' "$(locale_alias "$1")"
}

loc_table_ref() {
  local locale="$1"
  printf '%s %s' "$(ident "$(raw_location_table "$locale")")" "$(loc_alias "$locale")"
}

loc_col() {
  local locale="$1"
  local col="$2"
  printf '%s.%s' "$(loc_alias "$locale")" "$(ident "$col")"
}

join_location_locales_sql() {
  local base_alias="$1"
  local include_load_locales="$2"
  local locale
  local locales=("${SELECTED_LOCALES[@]}")
  if [[ "$include_load_locales" == "true" ]]; then
    locales=("${LOAD_LOCALES[@]}")
  fi
  for locale in "${locales[@]}"; do
    [[ "$locale" == "en" ]] && continue
    printf "LEFT JOIN %s %s ON %s.%s = %s.%s\n" \
      "$(ident "$(raw_location_table "$locale")")" "$(loc_alias "$locale")" \
      "$(loc_alias "$locale")" "$(ident geoname_id)" \
      "$base_alias" "$(ident geoname_id)"
  done
}

join_location_locales_inline_sql() {
  local base_alias="$1"
  local include_load_locales="$2"
  local locale
  local locales=("${SELECTED_LOCALES[@]}")
  if [[ "$include_load_locales" == "true" ]]; then
    locales=("${LOAD_LOCALES[@]}")
  fi
  for locale in "${locales[@]}"; do
    [[ "$locale" == "en" ]] && continue
    printf "LEFT JOIN %s %s ON %s.%s = %s.%s " \
      "$(ident "$(raw_location_table "$locale")")" "$(loc_alias "$locale")" \
      "$(loc_alias "$locale")" "$(ident geoname_id)" \
      "$base_alias" "$(ident geoname_id)"
  done
}

country_key_expr() {
  local alias="$1"
  if [[ "$DBMS" == "mysql" ]]; then
    printf "COALESCE(NULLIF(%s.%s, ''), CONCAT('#', %s.%s))" "$alias" "$(ident country_iso_code)" "$alias" "$(ident geoname_id)"
  else
    printf "COALESCE(NULLIF(%s.%s, ''), '#' || %s.%s::text)" "$alias" "$(ident country_iso_code)" "$alias" "$(ident geoname_id)"
  fi
}

emoji_iso_expr() {
  local alias="$1"
  printf "COALESCE(NULLIF(%s.%s, ''), '')" "$alias" "$(ident country_iso_code)"
}

regex_expr() {
  local alias="$1"
  local col="$2"
  local pattern="$3"
  local lit
  lit="$(sql_literal "$pattern")"
  if [[ "$DBMS" == "mysql" ]]; then
    printf "REGEXP_LIKE(COALESCE(%s.%s, ''), %s, 'i')" "$alias" "$(ident "$col")" "$lit"
  else
    printf "COALESCE(%s.%s::text, '') ~* %s" "$alias" "$(ident "$col")" "$lit"
  fi
}

filter_condition_sql() {
  local conditions=()
  local key value pattern locale expr group
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" && -n "$value" ]] || continue
    [[ "$key" =~ ^[A-Za-z0-9_]+$ ]] || die "Invalid location filter key: $key"
    group=""
    while IFS= read -r pattern; do
      [[ -n "$pattern" ]] || continue
      for locale in "${LOAD_LOCALES[@]}"; do
        expr="$(regex_expr "$(loc_alias "$locale")" "$key" "$pattern")"
        group="${group}${group:+ OR }$expr"
      done
    done < <(printf '%s\n' "$value" | split_config_list)
    [[ -n "$group" ]] && conditions+=("($group)")
  done < <(section_pairs location_filters)

  if [[ "${#conditions[@]}" -eq 0 ]]; then
    printf '1=1'
    return
  fi
  local first=true
  for expr in "${conditions[@]}"; do
    if [[ "$first" == "true" ]]; then first=false; else printf ' AND '; fi
    printf '%s' "$expr"
  done
}

field_alias() {
  case "$1" in
    geoname_id) echo "g_geo" ;;
    registered_country_geoname_id) echo "g_reg" ;;
    represented_country_geoname_id) echo "g_repr" ;;
    *) die "Unsupported priority field: $1" ;;
  esac
}

raw_geo_index_suffix() {
  case "$1" in
    geoname_id) echo "geo" ;;
    registered_country_geoname_id) echo "rgeo" ;;
    represented_country_geoname_id) echo "reprgeo" ;;
    *) die "Unsupported raw geo index field: $1" ;;
  esac
}

ip_geo_fields_for_transform() {
  local table="$1"
  local fields=()
  local field
  for field in "${PRIORITY_FIELDS[@]}"; do
    array_contains "$field" "${fields[@]}" || fields+=("$field")
  done
  for field in geoname_id registered_country_geoname_id represented_country_geoname_id; do
    if column_enabled "$table" "$field" && ! array_contains "$field" "${fields[@]}"; then
      fields+=("$field")
    fi
  done
  printf '%s\n' "${fields[@]}"
}

egeo_case_expr() {
  local field alias
  printf "CASE\n"
  for field in "${PRIORITY_FIELDS[@]}"; do
    alias="$(field_alias "$field")"
    if [[ "$DBMS" == "mysql" ]]; then
      printf "    WHEN %s.%s IS NOT NULL AND %s.%s = 1 THEN b.%s\n" "$alias" "$(ident geoname_id)" "$alias" "$(ident has_country_iso)" "$(ident "$field")"
    else
      printf "    WHEN %s.%s IS NOT NULL AND %s.%s IS TRUE THEN b.%s\n" "$alias" "$(ident geoname_id)" "$alias" "$(ident has_country_iso)" "$(ident "$field")"
    fi
  done
  for field in "${PRIORITY_FIELDS[@]}"; do
    alias="$(field_alias "$field")"
    printf "    WHEN %s.%s IS NOT NULL THEN b.%s\n" "$alias" "$(ident geoname_id)" "$(ident "$field")"
  done
  printf "    ELSE NULL\nEND"
}

geoname_source_code() {
  case "$1" in
    geoname_id) printf '1' ;;
    registered_country_geoname_id) printf '2' ;;
    represented_country_geoname_id) printf '3' ;;
    *) die "Unsupported effective geoname source field: $1" ;;
  esac
}

egeo_source_case_expr() {
  local field alias source_code
  printf "CASE\n"
  for field in "${PRIORITY_FIELDS[@]}"; do
    alias="$(field_alias "$field")"
    source_code="$(geoname_source_code "$field")"
    if [[ "$DBMS" == "mysql" ]]; then
      printf "    WHEN %s.%s IS NOT NULL AND %s.%s = 1 THEN %s\n" "$alias" "$(ident geoname_id)" "$alias" "$(ident has_country_iso)" "$source_code"
    else
      printf "    WHEN %s.%s IS NOT NULL AND %s.%s IS TRUE THEN %s\n" "$alias" "$(ident geoname_id)" "$alias" "$(ident has_country_iso)" "$source_code"
    fi
  done
  for field in "${PRIORITY_FIELDS[@]}"; do
    alias="$(field_alias "$field")"
    source_code="$(geoname_source_code "$field")"
    printf "    WHEN %s.%s IS NOT NULL THEN %s\n" "$alias" "$(ident geoname_id)" "$source_code"
  done
  printf "    ELSE NULL\nEND"
}

normalized_geo_expr() {
  local field="$1"
  local alias
  alias="$(field_alias "$field")"
  printf "CASE WHEN %s.%s IS NOT NULL THEN b.%s ELSE NULL END" "$alias" "$(ident geoname_id)" "$(ident "$field")"
}

write_mysql_inet6_function() {
  local file="$1"
  local definer=""
  [[ -n "$MYSQL_ROUTINE_DEFINER" ]] && definer="DEFINER=$MYSQL_ROUTINE_DEFINER "
  cat >> "$file" <<SQL
DELIMITER \$\$
DROP FUNCTION IF EXISTS $(mysql_ident inet6_aton_decimal)\$\$
CREATE ${definer}FUNCTION $(mysql_ident inet6_aton_decimal)(ip VARCHAR(45)) RETURNS DECIMAL(39,0)
    READS SQL DATA
    DETERMINISTIC
BEGIN
    DECLARE h VARCHAR(32);
    SET h = HEX(INET6_ATON(ip));
    IF h IS NULL THEN
        RETURN NULL;
    END IF;
    IF LENGTH(h) <= 8 THEN
        RETURN CAST(CONV(h, 16, 10) AS DECIMAL(39,0));
    END IF;
    SET h = LPAD(h, 32, '0');
    RETURN
        CAST(CONV(SUBSTR(h, 1, 8), 16, 10) AS DECIMAL(39,0)) * 79228162514264337593543950336 +
        CAST(CONV(SUBSTR(h, 9, 8), 16, 10) AS DECIMAL(39,0)) * 18446744073709551616 +
        CAST(CONV(SUBSTR(h, 17, 8), 16, 10) AS DECIMAL(39,0)) * 4294967296 +
        CAST(CONV(SUBSTR(h, 25, 8), 16, 10) AS DECIMAL(39,0));
END\$\$
DELIMITER ;

SQL
}

write_00_create_raw() {
  local file="$RUN_DIR/00_create_raw.sql"
  local table locale version
  start_sql_file "$file" "Raw import tables"
  {
    if [[ "$DBMS" == "mysql" ]]; then
      echo "SET FOREIGN_KEY_CHECKS=0;"
    fi
    if is_location_family; then
      for locale in "${LOAD_LOCALES[@]}"; do
        echo "DROP TABLE IF EXISTS $(ident "$(raw_location_table "$locale")");"
      done
    fi
    for version in "${IP_VERSIONS[@]}"; do
      echo "DROP TABLE IF EXISTS $(ident "$(raw_blocks_table "$version")");"
    done
    if has_enterprise_isp; then
      echo "DROP TABLE IF EXISTS $(ident "$(raw_isp_table)");"
    fi
    if is_location_family; then
      echo "DROP TABLE IF EXISTS $(ident "raw_emoji__load_$RUN_ID");"
    fi
    echo
    if [[ "$DBMS" == "mysql" ]]; then
      echo "SET FOREIGN_KEY_CHECKS=1;"
      echo
    fi
    if is_location_family; then
      for locale in "${LOAD_LOCALES[@]}"; do
        create_raw_location_sql "$(raw_location_table "$locale")" "$CSV_DIR/$CSV_PREFIX-Locations-$locale.csv"
      done
    fi
    for version in "${IP_VERSIONS[@]}"; do
      create_raw_blocks_sql "$(raw_blocks_table "$version")" "$CSV_DIR/$CSV_PREFIX-Blocks-IPv$version.csv"
    done
    if has_enterprise_isp; then
      create_raw_isp_sql "$(raw_isp_table)" "$CSV_DIR/$ENTERPRISE_ISP_CSV"
    fi
    if ! is_location_family; then
      :
    elif [[ "$DBMS" == "mysql" ]]; then
      cat <<SQL
CREATE TABLE $(ident "raw_emoji__load_$RUN_ID") (
  $(ident iso_code) CHAR(2) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
  $(ident emoji) CHAR(2) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY ($(ident iso_code))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

SQL
    else
      cat <<SQL
CREATE TABLE $(ident "raw_emoji__load_$RUN_ID") (
  $(ident iso_code) char(2) NOT NULL,
  $(ident emoji) char(2) DEFAULT NULL,
  PRIMARY KEY ($(ident iso_code))
);

SQL
    fi
  } >> "$file"
}

write_10_load_raw() {
  local file="$RUN_DIR/10_load_raw.sql"
  local locale version csv table cols
  start_sql_file "$file" "Import extracted MaxMind CSV files into raw tables"
  mysql_start_dml_transaction "$file" "Raw CSV import"
  if is_location_family; then
    for locale in "${LOAD_LOCALES[@]}"; do
      csv="$CSV_DIR/$CSV_PREFIX-Locations-$locale.csv"
      table="$(raw_location_table "$locale")"
      mapfile -t cols < <(header_columns "$csv")
      if [[ "$DBMS" == "mysql" ]]; then
        mysql_load_data_sql "$table" "$csv" "${cols[@]}" >> "$file"
      else
        pg_copy_sql "$table" "$csv" "${cols[@]}" >> "$file"
      fi
    done
  fi
  for version in "${IP_VERSIONS[@]}"; do
    csv="$CSV_DIR/$CSV_PREFIX-Blocks-IPv$version.csv"
    table="$(raw_blocks_table "$version")"
    mapfile -t cols < <(header_columns "$csv")
    if [[ "$DBMS" == "mysql" ]]; then
      mysql_load_data_sql "$table" "$csv" "${cols[@]}" >> "$file"
    else
      pg_copy_sql "$table" "$csv" "${cols[@]}" >> "$file"
    fi
  done
  if has_enterprise_isp; then
    csv="$CSV_DIR/$ENTERPRISE_ISP_CSV"
    table="$(raw_isp_table)"
    mapfile -t cols < <(header_columns "$csv")
    if [[ "$DBMS" == "mysql" ]]; then
      mysql_load_data_sql "$table" "$csv" "${cols[@]}" >> "$file"
    else
      pg_copy_sql "$table" "$csv" "${cols[@]}" >> "$file"
    fi
  fi
  if ! is_location_family; then
    :
  elif [[ "$DBMS" == "mysql" ]]; then
    cat >> "$file" <<SQL
LOAD DATA LOCAL INFILE $(sql_literal "$(to_client_path "$EMOJI_TSV")")
INTO TABLE $(ident "raw_emoji__load_$RUN_ID")
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '\t'
LINES TERMINATED BY '\n'
($(ident iso_code), $(ident emoji));

SQL
  else
    printf "\\copy %s (%s, %s) FROM %s WITH (FORMAT csv, DELIMITER E'\\t', NULL E'\\\\N');\n\n" \
      "$(ident "raw_emoji__load_$RUN_ID")" "$(ident iso_code)" "$(ident emoji)" "$(sql_literal "$(to_client_path "$EMOJI_TSV")")" >> "$file"
  fi
  mysql_commit_dml_transaction "$file"
}

write_raw_indexes_sql() {
  local file="$1"
  local locale version table field clauses suffix
  for locale in "${LOAD_LOCALES[@]}"; do
    table="$(raw_location_table "$locale")"
    if [[ "$DBMS" == "mysql" ]]; then
      echo "ALTER TABLE $(ident "$table") ADD INDEX $(ident "ix_${RUN_ID}_$(locale_alias "$locale")_geo") ($(ident geoname_id));" >> "$file"
    else
      echo "CREATE INDEX $(ident "ix_${RUN_ID}_$(locale_alias "$locale")_geo") ON $(ident "$table") ($(ident geoname_id));" >> "$file"
    fi
  done
  for version in "${IP_VERSIONS[@]}"; do
    table="$(raw_blocks_table "$version")"
    if [[ "$DBMS" == "mysql" ]]; then
      clauses=()
      while IFS= read -r field; do
        [[ -n "$field" ]] || continue
        suffix="$(raw_geo_index_suffix "$field")"
        clauses+=("ADD INDEX $(ident "ix_${RUN_ID}_raw_ipv${version}_${suffix}") ($(ident "$field"))")
      done < <(ip_geo_fields_for_transform "ipv$version")
      {
        printf "ALTER TABLE %s " "$(ident "$table")"
        join_sql_items ", " "${clauses[@]}"
        printf ";\n"
      } >> "$file"
    else
      while IFS= read -r field; do
        [[ -n "$field" ]] || continue
        suffix="$(raw_geo_index_suffix "$field")"
        echo "CREATE INDEX $(ident "ix_${RUN_ID}_raw_ipv${version}_${suffix}") ON $(ident "$table") ($(ident "$field"));" >> "$file"
      done < <(ip_geo_fields_for_transform "ipv$version")
    fi
  done
  echo >> "$file"
}

country_insert_parts() {
  local base="$1"
  local -n cols_ref="$2"
  local -n selects_ref="$3"
  local locale alias eu_expr
  cols_ref=()
  selects_ref=()
  if is_city_location; then
    cols_ref+=(id)
    selects_ref+=("cm.$(ident id)")
  else
    cols_ref+=(geoname_id)
    selects_ref+=("$base.$(ident geoname_id)")
  fi
  append_column_select_if_enabled cols_ref selects_ref country continent_code continent_code "$base.$(ident continent_code)"
  for locale in "${SELECTED_LOCALES[@]}"; do
    alias="$(loc_alias "$locale")"
    append_column_select_if_enabled cols_ref selects_ref country "continent_name_$locale" "continent_name_$locale" "$alias.$(ident continent_name)"
  done
  append_column_select_if_enabled cols_ref selects_ref country iso_code iso_code "$base.$(ident country_iso_code)"
  append_column_select_if_enabled cols_ref selects_ref country emoji emoji "e.$(ident emoji)"
  for locale in "${SELECTED_LOCALES[@]}"; do
    alias="$(loc_alias "$locale")"
    append_column_select_if_enabled cols_ref selects_ref country "name_$locale" "name_$locale" "$alias.$(ident country_name)"
  done
  if ! is_city_location; then
    if [[ "$DBMS" == "mysql" ]]; then
      eu_expr="COALESCE($base.$(ident is_in_european_union), 0)"
    else
      eu_expr="COALESCE($base.$(ident is_in_european_union), false)"
    fi
    append_column_select_if_enabled cols_ref selects_ref country is_in_european_union is_in_european_union "$eu_expr"
  fi
}

write_city_location_transforms() {
  local file="$1"
  local filter_table country_map sd1_map sd2_map tz_map locale table country_cols country_selects emoji_join
  filter_table="$(helper_name geoname_filter)"
  country_map="$(helper_name country_map)"
  sd1_map="$(helper_name subdivision1_map)"
  sd2_map="$(helper_name subdivision2_map)"
  tz_map="$(helper_name timezone_map)"
  emoji_join=""
  if column_enabled country emoji; then
    emoji_join="LEFT JOIN $(ident "raw_emoji__load_$RUN_ID") e ON e.$(ident iso_code) = $(emoji_iso_expr l_en)"
  fi

  cat >> "$file" <<SQL
CREATE TABLE $(ident "$country_map") AS
SELECT ROW_NUMBER() OVER (ORDER BY country_key) AS $(ident id), country_key, MIN($(ident geoname_id)) AS $(ident sample_geoname_id)
FROM (
  SELECT $(country_key_expr "l_en") AS country_key, l_en.$(ident geoname_id)
  FROM $(loc_table_ref en)
  JOIN $(ident "$filter_table") f ON f.$(ident geoname_id) = l_en.$(ident geoname_id)
) s
GROUP BY country_key;

SQL

  if [[ "$DBMS" == "mysql" ]]; then
    echo "ALTER TABLE $(ident "$country_map") ADD UNIQUE KEY $(ident "ix_${RUN_ID}_country_map_id") ($(ident id)), ADD UNIQUE KEY $(ident "ix_${RUN_ID}_country_map_key") ($(ident country_key));" >> "$file"
  else
    echo "CREATE UNIQUE INDEX $(ident "ix_${RUN_ID}_country_map_id") ON $(ident "$country_map") ($(ident id));" >> "$file"
    echo "CREATE UNIQUE INDEX $(ident "ix_${RUN_ID}_country_map_key") ON $(ident "$country_map") ($(ident country_key));" >> "$file"
  fi
  echo >> "$file"

  cat >> "$file" <<SQL
CREATE TABLE $(ident "$sd1_map") AS
SELECT ROW_NUMBER() OVER (ORDER BY country_id, iso_code) AS $(ident id), country_id, iso_code, MIN($(ident geoname_id)) AS $(ident sample_geoname_id)
FROM (
  SELECT cm.$(ident id) AS country_id, l_en.$(ident subdivision_1_iso_code) AS iso_code, l_en.$(ident geoname_id)
  FROM $(loc_table_ref en)
  JOIN $(ident "$filter_table") f ON f.$(ident geoname_id) = l_en.$(ident geoname_id)
  JOIN $(ident "$country_map") cm ON cm.$(ident country_key) = $(country_key_expr "l_en")
  WHERE NULLIF(l_en.$(ident subdivision_1_iso_code), '') IS NOT NULL
) s
GROUP BY country_id, iso_code;

CREATE TABLE $(ident "$sd2_map") AS
SELECT ROW_NUMBER() OVER (ORDER BY country_id, iso_code) AS $(ident id), country_id, iso_code, MIN($(ident geoname_id)) AS $(ident sample_geoname_id)
FROM (
  SELECT cm.$(ident id) AS country_id, l_en.$(ident subdivision_2_iso_code) AS iso_code, l_en.$(ident geoname_id)
  FROM $(loc_table_ref en)
  JOIN $(ident "$filter_table") f ON f.$(ident geoname_id) = l_en.$(ident geoname_id)
  JOIN $(ident "$country_map") cm ON cm.$(ident country_key) = $(country_key_expr "l_en")
  WHERE NULLIF(l_en.$(ident subdivision_2_iso_code), '') IS NOT NULL
) s
GROUP BY country_id, iso_code;

CREATE TABLE $(ident "$tz_map") AS
SELECT ROW_NUMBER() OVER (ORDER BY time_zone) AS $(ident id), time_zone, MIN($(ident geoname_id)) AS $(ident sample_geoname_id)
FROM (
  SELECT l_en.$(ident time_zone) AS time_zone, l_en.$(ident geoname_id)
  FROM $(loc_table_ref en)
  JOIN $(ident "$filter_table") f ON f.$(ident geoname_id) = l_en.$(ident geoname_id)
  WHERE NULLIF(l_en.$(ident time_zone), '') IS NOT NULL
) s
GROUP BY time_zone;

SQL
  local helper_label
  for table in "$sd1_map" "$sd2_map" "$tz_map"; do
    case "$table" in
      "$sd1_map") helper_label="sd1_map" ;;
      "$sd2_map") helper_label="sd2_map" ;;
      *) helper_label="tz_map" ;;
    esac
    if [[ "$DBMS" == "mysql" ]]; then
      echo "ALTER TABLE $(ident "$table") ADD UNIQUE KEY $(ident "ix_${RUN_ID}_${helper_label}_id") ($(ident id));" >> "$file"
    else
      echo "CREATE UNIQUE INDEX $(ident "ix_${RUN_ID}_${helper_label}_id") ON $(ident "$table") ($(ident id));" >> "$file"
    fi
  done
  echo >> "$file"

  mysql_start_dml_transaction "$file" "Stage inserts"
  if final_table_enabled country; then
    country_insert_parts "l_en" country_cols country_selects
    cat >> "$file" <<SQL
INSERT INTO $(ident "$(stage_name country)") ($(columns_csv_ident "$DBMS" "${country_cols[@]}"))
SELECT $(join_sql_items ", " "${country_selects[@]}")
FROM $(ident "$country_map") cm
JOIN $(loc_table_ref en) ON l_en.$(ident geoname_id) = cm.$(ident sample_geoname_id)
$(join_location_locales_inline_sql "l_en" false)
$emoji_join;

SQL
  fi

  for level in 1 2; do
    local map_name iso_col name_col target cols selects cols_csv selects_sql
    if [[ "$level" == "1" ]]; then map_name="$sd1_map"; target="subdivision1"; iso_col="subdivision_1_iso_code"; name_col="subdivision_1_name"; else map_name="$sd2_map"; target="subdivision2"; iso_col="subdivision_2_iso_code"; name_col="subdivision_2_name"; fi
    final_table_enabled "$target" || continue
    cols=(id)
    selects=("m.$(ident id)")
    append_column_select_if_enabled cols selects "$target" iso_code iso_code "l_en.$(ident "$iso_col")"
    for locale in "${SELECTED_LOCALES[@]}"; do
      append_column_select_if_enabled cols selects "$target" "name_$locale" "name_$locale" "$(loc_alias "$locale").$(ident "$name_col")"
    done
    cols_csv="$(columns_csv_ident "$DBMS" "${cols[@]}")"
    selects_sql="$(join_sql_items ", " "${selects[@]}")"
    cat >> "$file" <<SQL
INSERT INTO $(ident "$(stage_name "$target")") ($cols_csv)
SELECT $selects_sql
FROM $(ident "$map_name") m
JOIN $(loc_table_ref en) ON l_en.$(ident geoname_id) = m.$(ident sample_geoname_id)
$(join_location_locales_sql "l_en" false);

SQL
  done

  if final_table_enabled timezone; then
    local tz_cols=(id) tz_selects=("m.$(ident id)") tz_cols_csv tz_selects_sql
    append_column_select_if_enabled tz_cols tz_selects timezone name name "m.$(ident time_zone)"
    tz_cols_csv="$(columns_csv_ident "$DBMS" "${tz_cols[@]}")"
    tz_selects_sql="$(join_sql_items ", " "${tz_selects[@]}")"
    cat >> "$file" <<SQL
INSERT INTO $(ident "$(stage_name timezone)") ($tz_cols_csv)
SELECT $tz_selects_sql
FROM $(ident "$tz_map") m;

SQL
  fi

  local city_cols city_selects city_cols_csv city_selects_sql eu_expr
  city_cols=(geoname_id)
  city_selects=("l_en.$(ident geoname_id)")
  append_column_select_if_enabled city_cols city_selects city country_id country_id "cm.$(ident id)"
  append_column_select_if_enabled city_cols city_selects city subdivision1_id subdivision1_id "sd1.$(ident id)"
  append_column_select_if_enabled city_cols city_selects city subdivision2_id subdivision2_id "sd2.$(ident id)"
  for locale in "${SELECTED_LOCALES[@]}"; do
    append_column_select_if_enabled city_cols city_selects city "name_$locale" "name_$locale" "$(loc_alias "$locale").$(ident city_name)"
  done
  append_column_select_if_enabled city_cols city_selects city metro_code metro_code "l_en.$(ident metro_code)"
  append_column_select_if_enabled city_cols city_selects city time_zone_id time_zone_id "tz.$(ident id)"
  if [[ "$DBMS" == "mysql" ]]; then
    eu_expr="COALESCE(l_en.$(ident is_in_european_union), 0)"
  else
    eu_expr="COALESCE(l_en.$(ident is_in_european_union), false)"
  fi
  append_column_select_if_enabled city_cols city_selects city is_in_european_union is_in_european_union "$eu_expr"
  city_cols_csv="$(columns_csv_ident "$DBMS" "${city_cols[@]}")"
  city_selects_sql="$(join_sql_items ", " "${city_selects[@]}")"
  cat >> "$file" <<SQL
INSERT INTO $(ident "$(stage_name city)") ($city_cols_csv)
SELECT $city_selects_sql
FROM $(loc_table_ref en)
JOIN $(ident "$filter_table") f ON f.$(ident geoname_id) = l_en.$(ident geoname_id)
JOIN $(ident "$country_map") cm ON cm.$(ident country_key) = $(country_key_expr "l_en")
LEFT JOIN $(ident "$sd1_map") sd1 ON sd1.country_id = cm.$(ident id) AND sd1.iso_code = l_en.$(ident subdivision_1_iso_code)
LEFT JOIN $(ident "$sd2_map") sd2 ON sd2.country_id = cm.$(ident id) AND sd2.iso_code = l_en.$(ident subdivision_2_iso_code)
LEFT JOIN $(ident "$tz_map") tz ON tz.time_zone = l_en.$(ident time_zone)
$(join_location_locales_inline_sql "l_en" false);

SQL
}

write_country_location_transform() {
  local file="$1"
  local filter_table country_cols country_selects country_cols_csv country_selects_sql emoji_join
  filter_table="$(helper_name geoname_filter)"
  emoji_join=""
  if column_enabled country emoji; then
    emoji_join="LEFT JOIN $(ident "raw_emoji__load_$RUN_ID") e ON e.$(ident iso_code) = $(emoji_iso_expr l_en)"
  fi
  country_insert_parts "l_en" country_cols country_selects
  country_cols_csv="$(columns_csv_ident "$DBMS" "${country_cols[@]}")"
  country_selects_sql="$(join_sql_items ", " "${country_selects[@]}")"
  cat >> "$file" <<SQL
INSERT INTO $(ident "$(stage_name country)") ($country_cols_csv)
SELECT $country_selects_sql
FROM $(loc_table_ref en)
JOIN $(ident "$filter_table") f ON f.$(ident geoname_id) = l_en.$(ident geoname_id)
$(join_location_locales_inline_sql "l_en" false)
$emoji_join;

SQL
}

write_enterprise_isp_transform() {
  local file="$1"
  local cols selects cols_csv selects_sql col
  final_table_enabled isp || return 0
  cols=(isp_id)
  selects=("r.$(ident isp_id)")
  while IFS= read -r col; do
    [[ -n "$col" && "$col" != "isp_id" ]] || continue
    if column_enabled isp "$col"; then
      cols+=("$col")
      selects+=("r.$(ident "$col")")
    fi
  done < <(header_columns "$CSV_DIR/$ENTERPRISE_ISP_CSV")
  cols_csv="$(columns_csv_ident "$DBMS" "${cols[@]}")"
  selects_sql="$(join_sql_items ", " "${selects[@]}")"
  cat >> "$file" <<SQL
INSERT INTO $(ident "$(stage_name isp)") ($cols_csv)
SELECT $selects_sql
FROM $(ident "$(raw_isp_table)") r
WHERE r.$(ident isp_id) IS NOT NULL;

SQL
}

write_ip_transform() {
  local file="$1"
  local version="$2"
  local raw table prefix_bits start_expr last_expr pow_join candidate source_candidate cols selects cols_csv selects_sql field alias
  raw="$(raw_blocks_table "$version")"
  table="ipv$version"
  candidate="$(egeo_case_expr)"
  source_candidate="$(egeo_source_case_expr)"
  cols=(network)
  selects=()

  if [[ "$DBMS" == "mysql" ]]; then
    prefix_bits="CAST(SUBSTRING_INDEX(b.$(ident network), '/', -1) AS UNSIGNED)"
    if [[ "$version" == "4" ]]; then
      start_expr="INET_ATON(SUBSTRING_INDEX(b.$(ident network), '/', 1))"
      pow_join="JOIN $(ident "pow2__load_$RUN_ID") p ON p.$(ident bits) = 32 - $prefix_bits"
    else
      start_expr="$(mysql_ident inet6_aton_decimal)(SUBSTRING_INDEX(b.$(ident network), '/', 1))"
      pow_join="JOIN $(ident "pow2__load_$RUN_ID") p ON p.$(ident bits) = 128 - $prefix_bits"
    fi
    last_expr="$start_expr + p.$(ident value) - 1"
    selects=("b.$(ident network)")
    cols+=(start_ip last_ip e_geoname_id e_geoname_source_code)
    selects+=("$start_expr" "$last_expr" "$candidate" "$source_candidate")
    append_column_select_if_enabled cols selects "$table" geoname_id geoname_id "$(normalized_geo_expr geoname_id)"
    append_column_select_if_enabled cols selects "$table" registered_country_geoname_id registered_country_geoname_id "$(normalized_geo_expr registered_country_geoname_id)"
    append_column_select_if_enabled cols selects "$table" represented_country_geoname_id represented_country_geoname_id "$(normalized_geo_expr represented_country_geoname_id)"
    append_column_select_if_enabled cols selects "$table" is_anonymous_proxy is_anonymous_proxy "COALESCE(b.$(ident is_anonymous_proxy), 0)"
    append_column_select_if_enabled cols selects "$table" is_satellite_provider is_satellite_provider "COALESCE(b.$(ident is_satellite_provider), 0)"
  else
    start_expr="host(network(b.$(ident network)::cidr))::inet"
    last_expr="host(broadcast(b.$(ident network)::cidr))::inet"
    pow_join=""
    selects=("b.$(ident network)::cidr")
    cols+=(start_ip last_ip e_geoname_id e_geoname_source_code)
    selects+=("$start_expr" "$last_expr" "$candidate" "$source_candidate")
    append_column_select_if_enabled cols selects "$table" geoname_id geoname_id "$(normalized_geo_expr geoname_id)"
    append_column_select_if_enabled cols selects "$table" registered_country_geoname_id registered_country_geoname_id "$(normalized_geo_expr registered_country_geoname_id)"
    append_column_select_if_enabled cols selects "$table" represented_country_geoname_id represented_country_geoname_id "$(normalized_geo_expr represented_country_geoname_id)"
    append_column_select_if_enabled cols selects "$table" is_anonymous_proxy is_anonymous_proxy "COALESCE(b.$(ident is_anonymous_proxy), false)"
    append_column_select_if_enabled cols selects "$table" is_satellite_provider is_satellite_provider "COALESCE(b.$(ident is_satellite_provider), false)"
  fi
  append_block_header_selects cols selects "$table" b \
    network geoname_id registered_country_geoname_id represented_country_geoname_id is_anonymous_proxy is_satellite_provider
  cols_csv="$(columns_csv_ident "$DBMS" "${cols[@]}")"
  selects_sql="$(join_sql_items ", " "${selects[@]}")"
  cat >> "$file" <<SQL
INSERT INTO $(ident "$(stage_name "$table")") ($cols_csv)
SELECT $selects_sql
FROM $(ident "$raw") b
SQL
  while IFS= read -r field; do
    [[ -n "$field" ]] || continue
    alias="$(field_alias "$field")"
    echo "LEFT JOIN $(ident "$(helper_name geoname_filter)") $alias ON $alias.$(ident geoname_id) = b.$(ident "$field")" >> "$file"
  done < <(ip_geo_fields_for_transform "$table")
  cat >> "$file" <<SQL
$pow_join
;

SQL
}

write_generic_ip_transform() {
  local file="$1"
  local version="$2"
  local raw table prefix_bits start_expr last_expr pow_join cols selects cols_csv selects_sql col
  raw="$(raw_blocks_table "$version")"
  table="ipv$version"
  cols=(network)
  if [[ "$DBMS" == "mysql" ]]; then
    prefix_bits="CAST(SUBSTRING_INDEX(b.$(ident network), '/', -1) AS UNSIGNED)"
    if [[ "$version" == "4" ]]; then
      start_expr="INET_ATON(SUBSTRING_INDEX(b.$(ident network), '/', 1))"
      pow_join="JOIN $(ident "pow2__load_$RUN_ID") p ON p.$(ident bits) = 32 - $prefix_bits"
    else
      start_expr="$(mysql_ident inet6_aton_decimal)(SUBSTRING_INDEX(b.$(ident network), '/', 1))"
      pow_join="JOIN $(ident "pow2__load_$RUN_ID") p ON p.$(ident bits) = 128 - $prefix_bits"
    fi
    last_expr="$start_expr + p.$(ident value) - 1"
    cols+=(start_ip last_ip)
    selects=("b.$(ident network)" "$start_expr" "$last_expr")
  else
    start_expr="host(network(b.$(ident network)::cidr))::inet"
    last_expr="host(broadcast(b.$(ident network)::cidr))::inet"
    pow_join=""
    cols+=(start_ip last_ip)
    selects=("b.$(ident network)::cidr" "$start_expr" "$last_expr")
  fi
  while IFS= read -r col; do
    [[ -n "$col" && "$col" != "network" ]] || continue
    if column_enabled "$table" "$col"; then
      cols+=("$col")
      selects+=("b.$(ident "$col")")
    fi
  done < <(header_columns "$(block_csv_path "$table")")
  cols_csv="$(columns_csv_ident "$DBMS" "${cols[@]}")"
  selects_sql="$(join_sql_items ", " "${selects[@]}")"
  cat >> "$file" <<SQL
INSERT INTO $(ident "$(stage_name "$table")") ($cols_csv)
SELECT $selects_sql
FROM $(ident "$raw") b
$pow_join;

SQL
}

generate_pow2_values() {
  awk '
    function trim(s) { sub(/^0+/, "", s); return s == "" ? "0" : s }
    function mul2(a,    carry, d, p, out) {
      out = ""; carry = 0
      while (length(a) > 0 || carry > 0) {
        d = length(a) > 0 ? substr(a, length(a), 1) + 0 : 0
        p = d * 2 + carry
        out = (p % 10) out
        carry = int(p / 10)
        a = length(a) > 0 ? substr(a, 1, length(a) - 1) : ""
      }
      return trim(out)
    }
    BEGIN {
      v = "1"
      for (i = 0; i <= 128; i++) {
        printf "%s(%d, %s)", i == 0 ? "" : ",\n", i, v
        v = mul2(v)
      }
      print ";"
    }
  '
}

json_string_array_text() {
  local first=true value
  printf '['
  for value in "$@"; do
    if [[ "$first" == "true" ]]; then first=false; else printf ','; fi
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
  done
  printf ']'
}

json_number_array_text() {
  local first=true value
  printf '['
  for value in "$@"; do
    if [[ "$first" == "true" ]]; then first=false; else printf ','; fi
    printf '%s' "$value"
  done
  printf ']'
}

metadata_json_expr() {
  local json="$1"
  if [[ "$DBMS" == "mysql" ]]; then
    printf 'CAST(%s AS JSON)' "$(sql_literal "$json")"
  else
    printf '%s::jsonb' "$(sql_literal "$json")"
  fi
}

write_dataset_metadata_transform() {
  local file="$1"
  local source_build_date="NULL" imported_at
  local ip_versions_json selected_locales_json loaded_locales_json priority_json
  local sorted_ip_versions=() sorted_selected_locales=() sorted_loaded_locales=()

  mapfile -t sorted_ip_versions < <(printf '%s\n' "${IP_VERSIONS[@]}" | sort -n -u)
  ip_versions_json="$(json_number_array_text "${sorted_ip_versions[@]}")"
  if is_location_family; then
    mapfile -t sorted_selected_locales < <(printf '%s\n' "${SELECTED_LOCALES[@]}" | sort -u)
    mapfile -t sorted_loaded_locales < <(printf '%s\n' "${LOAD_LOCALES[@]}" | sort -u)
    selected_locales_json="$(json_string_array_text "${sorted_selected_locales[@]}")"
    loaded_locales_json="$(json_string_array_text "${sorted_loaded_locales[@]}")"
    priority_json="$(json_string_array_text "${PRIORITY_FIELDS[@]}")"
  else
    selected_locales_json='[]'
    loaded_locales_json='[]'
    priority_json='[]'
  fi
  if [[ "$ARCHIVE_BUILD_DATE" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})$ ]]; then
    source_build_date="$(sql_literal "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}")"
  fi
  if [[ "$DBMS" == "mysql" ]]; then
    imported_at="UTC_TIMESTAMP(6)"
  else
    imported_at="CURRENT_TIMESTAMP"
  fi

  cat >> "$file" <<SQL
INSERT INTO $(ident "$(stage_name dataset_metadata)") (
  $(ident run_id), $(ident edition_id), $(ident archive_root), $(ident source_build_date),
  $(ident imported_at), $(ident converter_version), $(ident schema_version), $(ident dbms),
  $(ident project_name), $(ident schema_name), $(ident ip_versions), $(ident selected_locales),
  $(ident loaded_locales), $(ident e_geoname_id_priority_columns)
) VALUES (
  $(sql_literal "$BUILD_RUN_ID"), $(sql_literal "$ARCHIVE_EDITION_ID"), $(sql_literal "$ARCHIVE_ROOT"), $source_build_date,
  $imported_at, $(sql_literal "$CONVERTER_VERSION"), $SCHEMA_VERSION, $(sql_literal "$DBMS"),
  $(sql_literal "$CONFIG_PROJECT_NAME"), $(sql_literal "$SCHEMA_NAME"), $(metadata_json_expr "$ip_versions_json"), $(metadata_json_expr "$selected_locales_json"),
  $(metadata_json_expr "$loaded_locales_json"), $(metadata_json_expr "$priority_json")
);

SQL
}

write_20_transform_stage() {
  local file="$RUN_DIR/20_transform_stage.sql"
  local table locale version filter_table
  filter_table="$(helper_name geoname_filter)"
  start_sql_file "$file" "Build normalized staging tables from raw CSV tables"

  if [[ "$DBMS" == "mysql" && " ${IP_VERSIONS[*]} " == *" 6 "* ]]; then
    write_mysql_inet6_function "$file"
  fi

  if [[ "$DBMS" == "mysql" ]]; then
    echo "SET FOREIGN_KEY_CHECKS=0;" >> "$file"
  fi
  for table in $(final_table_order); do
    echo "DROP TABLE IF EXISTS $(ident "$(stage_name "$table")");" >> "$file"
  done
  for helper in geoname_filter country_map subdivision1_map subdivision2_map timezone_map pow2; do
    echo "DROP TABLE IF EXISTS $(ident "$(helper_name "$helper")");" >> "$file"
  done
  if [[ "$DBMS" == "mysql" ]]; then
    echo "SET FOREIGN_KEY_CHECKS=1;" >> "$file"
  fi
  echo >> "$file"

  if is_location_family; then
    write_raw_indexes_sql "$file"
  fi

  for table in $(final_table_order); do
    write_table_ddl "$file" "$table"
  done

  if ! is_location_family; then
    if [[ "$DBMS" == "mysql" ]]; then
      cat >> "$file" <<SQL
CREATE TABLE $(ident "pow2__load_$RUN_ID") (
  $(ident bits) INT UNSIGNED NOT NULL,
  $(ident value) DECIMAL(39,0) UNSIGNED NOT NULL,
  PRIMARY KEY ($(ident bits))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

SQL
      mysql_start_dml_transaction "$file" "Stage inserts"
      cat >> "$file" <<SQL
INSERT INTO $(ident "pow2__load_$RUN_ID") ($(ident bits), $(ident value)) VALUES
$(generate_pow2_values)

SQL
    fi
    for version in "${IP_VERSIONS[@]}"; do
      write_generic_ip_transform "$file" "$version"
    done
    write_dataset_metadata_transform "$file"
    mysql_commit_dml_transaction "$file"
    return
  fi

  if [[ "$DBMS" == "mysql" ]]; then
    cat >> "$file" <<SQL
CREATE TABLE $(ident "$filter_table") AS
SELECT l_en.$(ident geoname_id), CASE WHEN NULLIF(l_en.$(ident country_iso_code), '') IS NULL THEN 0 ELSE 1 END AS $(ident has_country_iso)
FROM $(loc_table_ref en)
$(join_location_locales_inline_sql "l_en" true)
WHERE $(filter_condition_sql);

ALTER TABLE $(ident "$filter_table") ADD UNIQUE KEY $(ident "ix_${RUN_ID}_geoname_filter_geo") ($(ident geoname_id));

CREATE TABLE $(ident "pow2__load_$RUN_ID") (
  $(ident bits) INT UNSIGNED NOT NULL,
  $(ident value) DECIMAL(39,0) UNSIGNED NOT NULL,
  PRIMARY KEY ($(ident bits))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

SQL
  else
    cat >> "$file" <<SQL
CREATE TABLE $(ident "$filter_table") AS
SELECT l_en.$(ident geoname_id), CASE WHEN NULLIF(l_en.$(ident country_iso_code), '') IS NULL THEN false ELSE true END AS $(ident has_country_iso)
FROM $(loc_table_ref en)
$(join_location_locales_inline_sql "l_en" true)
WHERE $(filter_condition_sql);

CREATE UNIQUE INDEX $(ident "ix_${RUN_ID}_geoname_filter_geo") ON $(ident "$filter_table") ($(ident geoname_id));

SQL
  fi

  if is_city_location; then
    write_city_location_transforms "$file"
  else
    mysql_start_dml_transaction "$file" "Stage inserts"
    write_country_location_transform "$file"
  fi
  if [[ "$DBMS" == "mysql" ]]; then
    cat >> "$file" <<SQL
INSERT INTO $(ident "pow2__load_$RUN_ID") ($(ident bits), $(ident value)) VALUES
$(generate_pow2_values)

SQL
  fi
  write_enterprise_isp_transform "$file"
  for version in "${IP_VERSIONS[@]}"; do
    write_ip_transform "$file" "$version"
  done
  write_dataset_metadata_transform "$file"
  mysql_commit_dml_transaction "$file"
}

write_90_indexes_stage() {
  local file="$RUN_DIR/90_indexes_stage.sql"
  local table ref clauses constraints
  start_sql_file "$file" "Indexes and foreign keys for normalized staging tables"
  for table in $(final_table_order); do
    case "$table" in
      country)
        if column_enabled country iso_code; then
          if [[ "$DBMS" == "mysql" ]]; then
            echo "ALTER TABLE $(ident "$(stage_name country)") ADD UNIQUE KEY $(ident "ix_${RUN_ID}_country_iso") ($(ident iso_code));" >> "$file"
          else
            echo "CREATE UNIQUE INDEX $(ident "ix_${RUN_ID}_country_iso") ON $(ident "$(stage_name country)") ($(ident iso_code));" >> "$file"
          fi
        fi
        ;;
      timezone)
        if column_enabled timezone name; then
          if [[ "$DBMS" == "mysql" ]]; then
            echo "ALTER TABLE $(ident "$(stage_name timezone)") ADD UNIQUE KEY $(ident "ix_${RUN_ID}_timezone_name") ($(ident name));" >> "$file"
          else
            echo "CREATE UNIQUE INDEX $(ident "ix_${RUN_ID}_timezone_name") ON $(ident "$(stage_name timezone)") ($(ident name));" >> "$file"
          fi
        fi
        ;;
      subdivision1|subdivision2)
        if column_enabled "$table" iso_code; then
          if [[ "$DBMS" == "mysql" ]]; then
            echo "ALTER TABLE $(ident "$(stage_name "$table")") ADD KEY $(ident "ix_${RUN_ID}_${table}_iso") ($(ident iso_code));" >> "$file"
          else
            echo "CREATE INDEX $(ident "ix_${RUN_ID}_${table}_iso") ON $(ident "$(stage_name "$table")") ($(ident iso_code));" >> "$file"
          fi
        fi
        ;;
      city)
        if [[ "$DBMS" == "mysql" ]]; then
          clauses=()
          if column_enabled city country_id; then
            clauses+=("ADD KEY $(ident "ix_${RUN_ID}_city_country") ($(ident country_id))")
            clauses+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_city_country") FOREIGN KEY ($(ident country_id)) REFERENCES $(ident "$(stage_name country)") ($(ident id)) ON UPDATE CASCADE ON DELETE CASCADE")
          fi
          if column_enabled city subdivision1_id; then
            clauses+=("ADD KEY $(ident "ix_${RUN_ID}_city_sd1") ($(ident subdivision1_id))")
            clauses+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_city_sd1") FOREIGN KEY ($(ident subdivision1_id)) REFERENCES $(ident "$(stage_name subdivision1)") ($(ident id)) ON UPDATE CASCADE ON DELETE CASCADE")
          fi
          if column_enabled city subdivision2_id; then
            clauses+=("ADD KEY $(ident "ix_${RUN_ID}_city_sd2") ($(ident subdivision2_id))")
            clauses+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_city_sd2") FOREIGN KEY ($(ident subdivision2_id)) REFERENCES $(ident "$(stage_name subdivision2)") ($(ident id)) ON UPDATE CASCADE ON DELETE CASCADE")
          fi
          if column_enabled city time_zone_id; then
            clauses+=("ADD KEY $(ident "ix_${RUN_ID}_city_tz") ($(ident time_zone_id))")
            clauses+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_city_tz") FOREIGN KEY ($(ident time_zone_id)) REFERENCES $(ident "$(stage_name timezone)") ($(ident id)) ON UPDATE CASCADE ON DELETE CASCADE")
          fi
          if [[ "${#clauses[@]}" -gt 0 ]]; then
            {
              printf "ALTER TABLE %s\n  " "$(ident "$(stage_name city)")"
              join_sql_items $',\n  ' "${clauses[@]}"
              printf ";\n\n"
            } >> "$file"
          fi
        else
          constraints=()
          if column_enabled city country_id; then
            echo "CREATE INDEX $(ident "ix_${RUN_ID}_city_country") ON $(ident "$(stage_name city)") ($(ident country_id));" >> "$file"
            constraints+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_city_country") FOREIGN KEY ($(ident country_id)) REFERENCES $(ident "$(stage_name country)") ($(ident id)) ON UPDATE CASCADE ON DELETE CASCADE")
          fi
          if column_enabled city subdivision1_id; then
            echo "CREATE INDEX $(ident "ix_${RUN_ID}_city_sd1") ON $(ident "$(stage_name city)") ($(ident subdivision1_id));" >> "$file"
            constraints+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_city_sd1") FOREIGN KEY ($(ident subdivision1_id)) REFERENCES $(ident "$(stage_name subdivision1)") ($(ident id)) ON UPDATE CASCADE ON DELETE CASCADE")
          fi
          if column_enabled city subdivision2_id; then
            echo "CREATE INDEX $(ident "ix_${RUN_ID}_city_sd2") ON $(ident "$(stage_name city)") ($(ident subdivision2_id));" >> "$file"
            constraints+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_city_sd2") FOREIGN KEY ($(ident subdivision2_id)) REFERENCES $(ident "$(stage_name subdivision2)") ($(ident id)) ON UPDATE CASCADE ON DELETE CASCADE")
          fi
          if column_enabled city time_zone_id; then
            echo "CREATE INDEX $(ident "ix_${RUN_ID}_city_tz") ON $(ident "$(stage_name city)") ($(ident time_zone_id));" >> "$file"
            constraints+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_city_tz") FOREIGN KEY ($(ident time_zone_id)) REFERENCES $(ident "$(stage_name timezone)") ($(ident id)) ON UPDATE CASCADE ON DELETE CASCADE")
          fi
          if [[ "${#constraints[@]}" -gt 0 ]]; then
            {
              printf "ALTER TABLE %s\n  " "$(ident "$(stage_name city)")"
              join_sql_items $',\n  ' "${constraints[@]}"
              printf ";\n\n"
            } >> "$file"
          fi
        fi
        ;;
      ipv4|ipv6)
        if ! is_location_family; then
          if [[ "$DBMS" == "mysql" ]]; then
            echo "ALTER TABLE $(ident "$(stage_name "$table")") ADD KEY $(ident "ix_${RUN_ID}_${table}_range") ($(ident start_ip) DESC,$(ident last_ip));" >> "$file"
          else
            echo "CREATE INDEX $(ident "ix_${RUN_ID}_${table}_range") ON $(ident "$(stage_name "$table")") ($(ident start_ip) DESC, $(ident last_ip));" >> "$file"
          fi
        else
          ref="country"
          is_city_location && ref="city"
          if [[ "$DBMS" == "mysql" ]]; then
            clauses=(
              "ADD KEY $(ident "ix_${RUN_ID}_${table}_range") ($(ident start_ip) DESC,$(ident last_ip))"
              "ADD KEY $(ident "ix_${RUN_ID}_${table}_egeo") ($(ident e_geoname_id))"
              "ADD CONSTRAINT $(ident "fk_${RUN_ID}_${table}_egeo") FOREIGN KEY ($(ident e_geoname_id)) REFERENCES $(ident "$(stage_name "$ref")") ($(ident geoname_id)) ON UPDATE RESTRICT ON DELETE RESTRICT"
            )
            if column_enabled "$table" geoname_id; then
              clauses+=("ADD KEY $(ident "ix_${RUN_ID}_${table}_geo") ($(ident geoname_id))")
              clauses+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_${table}_geo") FOREIGN KEY ($(ident geoname_id)) REFERENCES $(ident "$(stage_name "$ref")") ($(ident geoname_id)) ON UPDATE RESTRICT ON DELETE RESTRICT")
            fi
            if column_enabled "$table" registered_country_geoname_id; then
              clauses+=("ADD KEY $(ident "ix_${RUN_ID}_${table}_rgeo") ($(ident registered_country_geoname_id))")
              if [[ "$ARCHIVE_EDITION_KIND" == "Country" ]]; then
                clauses+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_${table}_rgeo") FOREIGN KEY ($(ident registered_country_geoname_id)) REFERENCES $(ident "$(stage_name "$ref")") ($(ident geoname_id)) ON UPDATE RESTRICT ON DELETE RESTRICT")
              fi
            fi
            if column_enabled "$table" represented_country_geoname_id; then
              clauses+=("ADD KEY $(ident "ix_${RUN_ID}_${table}_reprgeo") ($(ident represented_country_geoname_id))")
              if [[ "$ARCHIVE_EDITION_KIND" == "Country" ]]; then
                clauses+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_${table}_reprgeo") FOREIGN KEY ($(ident represented_country_geoname_id)) REFERENCES $(ident "$(stage_name "$ref")") ($(ident geoname_id)) ON UPDATE RESTRICT ON DELETE RESTRICT")
              fi
            fi
            if final_table_enabled isp && column_enabled "$table" isp_id; then
              clauses+=("ADD KEY $(ident "ix_${RUN_ID}_${table}_isp") ($(ident isp_id))")
              clauses+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_${table}_isp") FOREIGN KEY ($(ident isp_id)) REFERENCES $(ident "$(stage_name isp)") ($(ident isp_id)) ON UPDATE CASCADE ON DELETE CASCADE")
            fi
            {
              printf "ALTER TABLE %s\n  " "$(ident "$(stage_name "$table")")"
              join_sql_items $',\n  ' "${clauses[@]}"
              printf ";\n\n"
            } >> "$file"
          else
            echo "CREATE INDEX $(ident "ix_${RUN_ID}_${table}_range") ON $(ident "$(stage_name "$table")") ($(ident start_ip) DESC, $(ident last_ip));" >> "$file"
            echo "CREATE INDEX $(ident "ix_${RUN_ID}_${table}_egeo") ON $(ident "$(stage_name "$table")") ($(ident e_geoname_id));" >> "$file"
            constraints=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_${table}_egeo") FOREIGN KEY ($(ident e_geoname_id)) REFERENCES $(ident "$(stage_name "$ref")") ($(ident geoname_id)) ON UPDATE RESTRICT ON DELETE RESTRICT")
            if column_enabled "$table" geoname_id; then
              echo "CREATE INDEX $(ident "ix_${RUN_ID}_${table}_geo") ON $(ident "$(stage_name "$table")") ($(ident geoname_id));" >> "$file"
              constraints+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_${table}_geo") FOREIGN KEY ($(ident geoname_id)) REFERENCES $(ident "$(stage_name "$ref")") ($(ident geoname_id)) ON UPDATE RESTRICT ON DELETE RESTRICT")
            fi
            if column_enabled "$table" registered_country_geoname_id; then
              echo "CREATE INDEX $(ident "ix_${RUN_ID}_${table}_rgeo") ON $(ident "$(stage_name "$table")") ($(ident registered_country_geoname_id));" >> "$file"
              if [[ "$ARCHIVE_EDITION_KIND" == "Country" ]]; then
                constraints+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_${table}_rgeo") FOREIGN KEY ($(ident registered_country_geoname_id)) REFERENCES $(ident "$(stage_name "$ref")") ($(ident geoname_id)) ON UPDATE RESTRICT ON DELETE RESTRICT")
              fi
            fi
            if column_enabled "$table" represented_country_geoname_id; then
              echo "CREATE INDEX $(ident "ix_${RUN_ID}_${table}_reprgeo") ON $(ident "$(stage_name "$table")") ($(ident represented_country_geoname_id));" >> "$file"
              if [[ "$ARCHIVE_EDITION_KIND" == "Country" ]]; then
                constraints+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_${table}_reprgeo") FOREIGN KEY ($(ident represented_country_geoname_id)) REFERENCES $(ident "$(stage_name "$ref")") ($(ident geoname_id)) ON UPDATE RESTRICT ON DELETE RESTRICT")
              fi
            fi
            if final_table_enabled isp && column_enabled "$table" isp_id; then
              echo "CREATE INDEX $(ident "ix_${RUN_ID}_${table}_isp") ON $(ident "$(stage_name "$table")") ($(ident isp_id));" >> "$file"
              constraints+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_${table}_isp") FOREIGN KEY ($(ident isp_id)) REFERENCES $(ident "$(stage_name isp)") ($(ident isp_id)) ON UPDATE CASCADE ON DELETE CASCADE")
            fi
            {
              printf "ALTER TABLE %s\n  " "$(ident "$(stage_name "$table")")"
              join_sql_items $',\n  ' "${constraints[@]}"
              printf ";\n\n"
            } >> "$file"
          fi
        fi
        ;;
    esac
  done
}

mysql_promote_rename_index_sql() {
  local file="$1"
  local table="$2"
  local suffix="$3"
  echo "ALTER TABLE $(mysql_ident "$table") RENAME INDEX $(mysql_ident "ix_${RUN_ID}_${suffix}") TO $(mysql_ident "ix_${suffix}");" >> "$file"
}

mysql_promote_drop_fk_sql() {
  local file="$1"
  local table="$2"
  local suffix="$3"
  echo "ALTER TABLE $(mysql_ident "$table") DROP FOREIGN KEY $(mysql_ident "fk_${RUN_ID}_${suffix}");" >> "$file"
}

mysql_promote_add_fk_sql() {
  local file="$1"
  local table="$2"
  local suffix="$3"
  local column="$4"
  local ref_table="$5"
  local ref_column="$6"
  local actions="${7:-ON UPDATE CASCADE ON DELETE CASCADE}"
  echo "ALTER TABLE $(mysql_ident "$table") ADD CONSTRAINT $(mysql_ident "fk_${suffix}") FOREIGN KEY ($(mysql_ident "$column")) REFERENCES $(mysql_ident "$ref_table") ($(mysql_ident "$ref_column")) $actions;" >> "$file"
}

mysql_promote_fk_specs() {
  local file="$1"
  local action="$2"
  local table ref
  if is_city_location; then
    if column_enabled city country_id; then
      if [[ "$action" == "drop" ]]; then
        mysql_promote_drop_fk_sql "$file" city city_country
      else
        mysql_promote_add_fk_sql "$file" city city_country country_id country id
      fi
    fi
    if column_enabled city subdivision1_id; then
      if [[ "$action" == "drop" ]]; then
        mysql_promote_drop_fk_sql "$file" city city_sd1
      else
        mysql_promote_add_fk_sql "$file" city city_sd1 subdivision1_id subdivision1 id
      fi
    fi
    if column_enabled city subdivision2_id; then
      if [[ "$action" == "drop" ]]; then
        mysql_promote_drop_fk_sql "$file" city city_sd2
      else
        mysql_promote_add_fk_sql "$file" city city_sd2 subdivision2_id subdivision2 id
      fi
    fi
    if column_enabled city time_zone_id; then
      if [[ "$action" == "drop" ]]; then
        mysql_promote_drop_fk_sql "$file" city city_tz
      else
        mysql_promote_add_fk_sql "$file" city city_tz time_zone_id timezone id
      fi
    fi
  fi

  is_location_family || return 0
  ref="country"
  is_city_location && ref="city"
  for table in ipv4 ipv6; do
    array_contains "${table#ipv}" "${IP_VERSIONS[@]}" || continue
    if [[ "$action" == "drop" ]]; then
      mysql_promote_drop_fk_sql "$file" "$table" "${table}_egeo"
    else
      mysql_promote_add_fk_sql "$file" "$table" "${table}_egeo" e_geoname_id "$ref" geoname_id "ON UPDATE RESTRICT ON DELETE RESTRICT"
    fi
    if column_enabled "$table" geoname_id; then
      if [[ "$action" == "drop" ]]; then
        mysql_promote_drop_fk_sql "$file" "$table" "${table}_geo"
      else
        mysql_promote_add_fk_sql "$file" "$table" "${table}_geo" geoname_id "$ref" geoname_id "ON UPDATE RESTRICT ON DELETE RESTRICT"
      fi
    fi
    if [[ "$ARCHIVE_EDITION_KIND" == "Country" ]] && column_enabled "$table" registered_country_geoname_id; then
      if [[ "$action" == "drop" ]]; then
        mysql_promote_drop_fk_sql "$file" "$table" "${table}_rgeo"
      else
        mysql_promote_add_fk_sql "$file" "$table" "${table}_rgeo" registered_country_geoname_id "$ref" geoname_id "ON UPDATE RESTRICT ON DELETE RESTRICT"
      fi
    fi
    if [[ "$ARCHIVE_EDITION_KIND" == "Country" ]] && column_enabled "$table" represented_country_geoname_id; then
      if [[ "$action" == "drop" ]]; then
        mysql_promote_drop_fk_sql "$file" "$table" "${table}_reprgeo"
      else
        mysql_promote_add_fk_sql "$file" "$table" "${table}_reprgeo" represented_country_geoname_id "$ref" geoname_id "ON UPDATE RESTRICT ON DELETE RESTRICT"
      fi
    fi
    if final_table_enabled isp && column_enabled "$table" isp_id; then
      if [[ "$action" == "drop" ]]; then
        mysql_promote_drop_fk_sql "$file" "$table" "${table}_isp"
      else
        mysql_promote_add_fk_sql "$file" "$table" "${table}_isp" isp_id isp isp_id
      fi
    fi
  done
}

mysql_promote_rename_indexes() {
  local file="$1"
  local table
  if is_location_family; then
    if column_enabled country iso_code; then
      mysql_promote_rename_index_sql "$file" country country_iso
    fi
    if is_city_location; then
      if column_enabled timezone name; then
        mysql_promote_rename_index_sql "$file" timezone timezone_name
      fi
      for table in subdivision1 subdivision2; do
        if column_enabled "$table" iso_code; then
          mysql_promote_rename_index_sql "$file" "$table" "${table}_iso"
        fi
      done
      if column_enabled city country_id; then
        mysql_promote_rename_index_sql "$file" city city_country
      fi
      if column_enabled city subdivision1_id; then
        mysql_promote_rename_index_sql "$file" city city_sd1
      fi
      if column_enabled city subdivision2_id; then
        mysql_promote_rename_index_sql "$file" city city_sd2
      fi
      if column_enabled city time_zone_id; then
        mysql_promote_rename_index_sql "$file" city city_tz
      fi
    fi
  fi

  for table in ipv4 ipv6; do
    array_contains "${table#ipv}" "${IP_VERSIONS[@]}" || continue
    mysql_promote_rename_index_sql "$file" "$table" "${table}_range"
    is_location_family || continue
    mysql_promote_rename_index_sql "$file" "$table" "${table}_egeo"
    if column_enabled "$table" geoname_id; then
      mysql_promote_rename_index_sql "$file" "$table" "${table}_geo"
    fi
    if column_enabled "$table" registered_country_geoname_id; then
      mysql_promote_rename_index_sql "$file" "$table" "${table}_rgeo"
    fi
    if column_enabled "$table" represented_country_geoname_id; then
      mysql_promote_rename_index_sql "$file" "$table" "${table}_reprgeo"
    fi
    if final_table_enabled isp && column_enabled "$table" isp_id; then
      mysql_promote_rename_index_sql "$file" "$table" "${table}_isp"
    fi
  done
}

write_mysql_promote_name_cleanup() {
  local file="$1"
  {
    echo
    echo "SET FOREIGN_KEY_CHECKS=1;"
    echo
  } >> "$file"
  mysql_promote_fk_specs "$file" drop
  echo >> "$file"
  mysql_promote_rename_indexes "$file"
  echo >> "$file"
  mysql_promote_fk_specs "$file" add
}

write_98_promote() {
  local file="$RUN_DIR/98_promote.sql"
  local table renames=() rename_sql item pg_final_tables_sql
  start_sql_file "$file" "Atomically promote staging tables to production table names"
  if [[ "$DBMS" == "mysql" ]]; then
    echo "SET FOREIGN_KEY_CHECKS=0;" >> "$file"
    for table in $(final_table_order); do
      echo "DROP TABLE IF EXISTS $(ident "${table}__old_$RUN_ID");" >> "$file"
    done
    for table in $(final_table_order); do
      echo "CREATE TABLE IF NOT EXISTS $(ident "$table") LIKE $(ident "$(stage_name "$table")");" >> "$file"
      renames+=("$(ident "$table") TO $(ident "${table}__old_$RUN_ID")")
      renames+=("$(ident "$(stage_name "$table")") TO $(ident "$table")")
    done
    rename_sql=""
    for item in "${renames[@]}"; do
      rename_sql="${rename_sql}${rename_sql:+,\n  }$item"
    done
    printf "RENAME TABLE\n  %b;\n" "$rename_sql" >> "$file"
    for table in $(final_table_order_reversed); do
      echo "DROP TABLE IF EXISTS $(ident "${table}__old_$RUN_ID");" >> "$file"
    done
    write_mysql_promote_name_cleanup "$file"
  else
    pg_final_tables_sql=""
    for table in $(final_table_order); do
      pg_final_tables_sql="${pg_final_tables_sql}${pg_final_tables_sql:+, }'$table'"
    done
    cat >> "$file" <<SQL
DO \$\$
DECLARE
  item record;
BEGIN
SQL
    for table in $(final_table_order_reversed); do
      echo "  EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident('${table}__old_$RUN_ID');" >> "$file"
    done
    for table in $(final_table_order); do
      cat >> "$file" <<SQL
  IF to_regclass(current_schema() || '.$table') IS NOT NULL THEN
    EXECUTE 'ALTER TABLE ' || quote_ident('$table') || ' RENAME TO ' || quote_ident('${table}__old_$RUN_ID');
  END IF;
  EXECUTE 'ALTER TABLE ' || quote_ident('$(stage_name "$table")') || ' RENAME TO ' || quote_ident('$table');
SQL
    done
    for table in $(final_table_order_reversed); do
      echo "  EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident('${table}__old_$RUN_ID');" >> "$file"
    done
    cat >> "$file" <<SQL
  FOR item IN
    SELECT c.relname AS old_name, regexp_replace(c.relname, '^ix_${RUN_ID}_', 'ix_') AS new_name
    FROM pg_class c
    JOIN pg_index i ON i.indexrelid = c.oid
    JOIN pg_class t ON t.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = current_schema()
      AND t.relname IN ($pg_final_tables_sql)
      AND c.relname ~ '^ix_${RUN_ID}_'
  LOOP
    EXECUTE 'ALTER INDEX ' || quote_ident(item.old_name) || ' RENAME TO ' || quote_ident(item.new_name);
  END LOOP;

  FOR item IN
    SELECT t.relname AS table_name, con.conname AS old_name, t.relname || '_pkey' AS new_name
    FROM pg_constraint con
    JOIN pg_class t ON t.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = current_schema()
      AND t.relname IN ($pg_final_tables_sql)
      AND con.contype = 'p'
      AND con.conname ~ '__load_${RUN_ID}_pkey$'
  LOOP
    EXECUTE 'ALTER TABLE ' || quote_ident(item.table_name) || ' RENAME CONSTRAINT ' || quote_ident(item.old_name) || ' TO ' || quote_ident(item.new_name);
  END LOOP;

  FOR item IN
    SELECT t.relname AS table_name, con.conname AS old_name, regexp_replace(con.conname, '^fk_${RUN_ID}_', 'fk_') AS new_name
    FROM pg_constraint con
    JOIN pg_class t ON t.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = current_schema()
      AND t.relname IN ($pg_final_tables_sql)
      AND con.conname ~ '^fk_${RUN_ID}_'
  LOOP
    EXECUTE 'ALTER TABLE ' || quote_ident(item.table_name) || ' RENAME CONSTRAINT ' || quote_ident(item.old_name) || ' TO ' || quote_ident(item.new_name);
  END LOOP;

SQL
    echo "END \$\$;" >> "$file"
  fi
}

locale_text_expr() {
  local alias="$1"
  local table="$2"
  local base="$3"
  local locale="$4"
  if column_enabled "$table" "${base}_$locale"; then
    printf '%s.%s' "$alias" "$(ident "${base}_$locale")"
  fi
}

dedup_expr() {
  local expr="$1"
  shift
  local compares=("$@")
  local condition="" compare
  if [[ "${#compares[@]}" -eq 0 ]]; then
    printf "NULLIF(%s, '')" "$expr"
    return
  fi
  for compare in "${compares[@]}"; do
    condition="${condition}${condition:+ OR }$expr = $compare"
  done
  printf "NULLIF(CASE WHEN %s THEN NULL ELSE %s END, '')" "$condition" "$expr"
}

concat_expr() {
  local fn
  [[ "$DBMS" == "mysql" ]] && fn="CONCAT" || fn="concat"
  printf "%s(" "$fn"
  join_sql_items ", " "$@"
  printf ")"
}

concat_ws_expr() {
  local separator="$1"
  shift
  local fn
  [[ "$DBMS" == "mysql" ]] && fn="CONCAT_WS" || fn="concat_ws"
  printf "%s(%s" "$fn" "$separator"
  if [[ "$#" -gt 0 ]]; then
    printf ", "
    join_sql_items ", " "$@"
  fi
  printf ")"
}

coalesce_expr() {
  local exprs=("$@")
  if [[ "${#exprs[@]}" -eq 0 ]]; then
    return 0
  elif [[ "${#exprs[@]}" -eq 1 ]]; then
    printf '%s' "${exprs[0]}"
  else
    printf 'COALESCE('
    join_sql_items ", " "${exprs[@]}"
    printf ')'
  fi
}

preferred_locale_text_expr() {
  local alias="$1"
  local table="$2"
  local base="$3"
  local locale_sql="$4"
  local locale normalized available=() fallback=() branch=() field

  for locale in "${SELECTED_LOCALES[@]}"; do
    if column_enabled "$table" "${base}_$locale"; then
      available+=("$locale")
    fi
  done
  [[ "${#available[@]}" -gt 0 ]] || return 0

  if array_contains en "${available[@]}"; then
    fallback+=("$alias.$(ident "${base}_en")")
  fi
  for locale in "${available[@]}"; do
    [[ "$locale" == "en" ]] && continue
    fallback+=("$alias.$(ident "${base}_$locale")")
  done

  # Accept both a plain SQL locale ('ru') and an accidentally JSON-encoded
  # locale ('"ru"'). Fallback remains component-by-component.
  normalized="LOWER(REPLACE(TRIM(BOTH '\"' FROM TRIM(COALESCE($locale_sql, ''))), '_', '-'))"
  printf 'CASE %s ' "$normalized"
  for locale in "${available[@]}"; do
    branch=("$alias.$(ident "${base}_$locale")")
    for field in "${fallback[@]}"; do
      [[ "$field" == "${branch[0]}" ]] || branch+=("$field")
    done
    printf 'WHEN %s THEN %s ' "$(sql_literal "${locale,,}")" "$(coalesce_expr "${branch[@]}")"
  done
  printf 'ELSE %s END' "$(coalesce_expr "${fallback[@]}")"
}

location_label_expr() {
  local locale_sql="$1"
  local include_continent_sql="$2"
  local include_iso_sql="$3"
  local include_emoji_sql="$4"
  local c_cont="" c_name="" c_label="" c_iso="" c_emoji="" sd1="" sd2="" ci=""
  local parts=() country_parts=() compares=()

  if [[ "${ARCHIVE_LOCATION_KIND,,}" == "country" ]] || column_enabled city country_id; then
    c_cont="$(preferred_locale_text_expr c country continent_name "$locale_sql")"
    c_name="$(preferred_locale_text_expr c country name "$locale_sql")"
    if column_enabled country emoji; then
      c_emoji="CASE WHEN $include_emoji_sql = 1 THEN NULLIF(c.$(ident emoji), '') ELSE NULL END"
      country_parts+=("$c_emoji")
    fi
    if column_enabled country iso_code; then
      c_iso="CASE WHEN $include_iso_sql = 1 AND NULLIF(c.$(ident iso_code), '') IS NOT NULL THEN $(concat_expr "'['" "c.$(ident iso_code)" "']'") ELSE NULL END"
      country_parts+=("$c_iso")
    fi
    [[ -n "$c_name" ]] && country_parts+=("$c_name")
    if [[ "${#country_parts[@]}" -gt 0 ]]; then
      c_label="$(concat_ws_expr "' '" "${country_parts[@]}")"
    fi
  fi

  [[ -n "$c_cont" ]] && parts+=("CASE WHEN $include_continent_sql = 1 THEN $c_cont ELSE NULL END")
  [[ -n "$c_label" ]] && parts+=("NULLIF($c_label, '')")

  if is_city_location; then
    if column_enabled city subdivision1_id; then
      sd1="$(preferred_locale_text_expr sd1 subdivision1 name "$locale_sql")"
    fi
    if column_enabled city subdivision2_id; then
      sd2="$(preferred_locale_text_expr sd2 subdivision2 name "$locale_sql")"
    fi
    ci="$(preferred_locale_text_expr ci city name "$locale_sql")"

    if [[ -n "$sd1" ]]; then
      compares=()
      [[ -n "$c_name" ]] && compares+=("$c_name")
      [[ -n "$ci" ]] && compares+=("$ci")
      parts+=("$(dedup_expr "$sd1" "${compares[@]}")")
    fi
    if [[ -n "$sd2" ]]; then
      compares=()
      [[ -n "$c_name" ]] && compares+=("$c_name")
      [[ -n "$ci" ]] && compares+=("$ci")
      [[ -n "$sd1" ]] && compares+=("$sd1")
      parts+=("$(dedup_expr "$sd2" "${compares[@]}")")
    fi
    if [[ -n "$ci" ]]; then
      compares=()
      [[ -n "$c_name" ]] && compares+=("$c_name")
      parts+=("$(dedup_expr "$ci" "${compares[@]}")")
    fi
  fi

  [[ "${#parts[@]}" -gt 0 ]] || return 0
  concat_ws_expr "' - '" "${parts[@]}"
}

write_city_lookup_from_sql() {
  local file="$1"
  local indent="$2"
  echo "${indent}FROM $(ident city) ci" >> "$file"
  if column_enabled city country_id; then
    echo "${indent}JOIN $(ident country) c ON ci.$(ident country_id) = c.$(ident id)" >> "$file"
  fi
  if column_enabled city subdivision1_id; then
    echo "${indent}LEFT JOIN $(ident subdivision1) sd1 ON ci.$(ident subdivision1_id) = sd1.$(ident id)" >> "$file"
  fi
  if column_enabled city subdivision2_id; then
    echo "${indent}LEFT JOIN $(ident subdivision2) sd2 ON ci.$(ident subdivision2_id) = sd2.$(ident id)" >> "$file"
  fi
}

write_country_lookup_from_sql() {
  local file="$1"
  local indent="$2"
  echo "${indent}FROM $(ident country) c" >> "$file"
}

write_geoname_lookup_from_sql() {
  local file="$1"
  local indent="$2"
  if is_city_location; then
    write_city_lookup_from_sql "$file" "$indent"
  else
    write_country_lookup_from_sql "$file" "$indent"
  fi
}

write_geoname_lookup_from_input_sql() {
  local file="$1"
  local indent="$2"
  local geoname_expr="$3"
  echo "${indent}FROM input i" >> "$file"
  if is_city_location; then
    echo "${indent}LEFT JOIN $(ident city) ci ON ci.$(ident geoname_id) = $geoname_expr" >> "$file"
    if column_enabled city country_id; then
      echo "${indent}LEFT JOIN $(ident country) c ON ci.$(ident country_id) = c.$(ident id)" >> "$file"
    fi
    if column_enabled city subdivision1_id; then
      echo "${indent}LEFT JOIN $(ident subdivision1) sd1 ON ci.$(ident subdivision1_id) = sd1.$(ident id)" >> "$file"
    fi
    if column_enabled city subdivision2_id; then
      echo "${indent}LEFT JOIN $(ident subdivision2) sd2 ON ci.$(ident subdivision2_id) = sd2.$(ident id)" >> "$file"
    fi
  else
    echo "${indent}LEFT JOIN $(ident country) c ON c.$(ident geoname_id) = $geoname_expr" >> "$file"
  fi
}

routine_select_parts() {
  local -n names_ref="$1"
  local -n exprs_ref="$2"
  local -n types_ref="$3"
  local kind="${ARCHIVE_LOCATION_KIND,,}"
  local locale expr
  names_ref=()
  exprs_ref=()
  types_ref=()
  if [[ "$ROUTINE_SELECT_PARTS_CACHE_READY" == "true" ]]; then
    names_ref=("${ROUTINE_SELECT_NAMES_CACHE[@]}")
    exprs_ref=("${ROUTINE_SELECT_EXPRS_CACHE[@]}")
    types_ref=("${ROUTINE_SELECT_TYPES_CACHE[@]}")
    return
  fi
  if [[ "$kind" == "country" ]] || { [[ "$kind" == "city" ]] && column_enabled city country_id; }; then
    if column_enabled country iso_code; then
      names_ref+=(country_iso_code)
      exprs_ref+=("c.$(ident iso_code)")
      types_ref+=("char(2)")
    fi
  fi
  for locale in "${SELECTED_LOCALES[@]}"; do
    expr="$(location_label_expr "$(sql_literal "$locale")" include_continent include_iso_code include_emoji)"
    if [[ -n "$expr" ]]; then
      names_ref+=("location_$(locale_alias "$locale")")
      exprs_ref+=("$expr")
      types_ref+=("text")
    fi
  done
  ROUTINE_SELECT_NAMES_CACHE=("${names_ref[@]}")
  ROUTINE_SELECT_EXPRS_CACHE=("${exprs_ref[@]}")
  ROUTINE_SELECT_TYPES_CACHE=("${types_ref[@]}")
  ROUTINE_SELECT_PARTS_CACHE_READY=true
}

write_mysql_build_location_function() {
  local file="$1"
  local definer="$2"
  local name="$3"
  local args="$4"
  local expr="$5"
  local where_expr
  if is_city_location; then
    where_expr="ci.$(mysql_ident geoname_id) = geoname_id_param"
  else
    where_expr="c.$(mysql_ident geoname_id) = geoname_id_param"
  fi
  cat >> "$file" <<SQLP
DROP FUNCTION IF EXISTS $(mysql_ident "$name")\$\$
CREATE ${definer}FUNCTION $(mysql_ident "$name")($args) RETURNS TEXT CHARSET utf8mb4
    READS SQL DATA
    DETERMINISTIC
    SQL SECURITY INVOKER
BEGIN
    DECLARE result TEXT DEFAULT NULL;
    SELECT
        $expr
    INTO result
SQLP
  write_geoname_lookup_from_sql "$file" "    "
  cat >> "$file" <<SQL
    WHERE $where_expr;
    RETURN result;
END\$\$

SQL
}

write_mysql_build_location_functions() {
  local file="$1"
  local definer="$2"
  local expr
  echo "DROP FUNCTION IF EXISTS $(mysql_ident build_location_label)\$\$" >> "$file"
  expr="$(location_label_expr locale_param include_continent include_iso_code include_emoji)"
  if [[ -n "$expr" ]]; then
    write_mysql_build_location_function "$file" "$definer" build_location_label_by_geoname_id "geoname_id_param INT UNSIGNED, locale_param VARCHAR(16), include_continent INT UNSIGNED, include_iso_code INT UNSIGNED, include_emoji INT UNSIGNED" "$expr"
  else
    cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(mysql_ident build_location_label_by_geoname_id)\$\$
-- build_location_label_by_geoname_id was not generated because no configured output columns can be returned.

SQL
  fi
}

write_pg_build_location_function() {
  local file="$1"
  local name="$2"
  local signature="$3"
  local args="$4"
  local expr="$5"
  local where_expr
  if is_city_location; then
    where_expr="ci.$(pg_ident geoname_id) = geoname_id_param"
  else
    where_expr="c.$(pg_ident geoname_id) = geoname_id_param"
  fi
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident "$name")($signature);

CREATE OR REPLACE FUNCTION $(pg_ident "$name")($args)
RETURNS text
LANGUAGE sql
STABLE
SECURITY INVOKER
$(pg_routine_search_path_clause)
AS \$\$
SELECT
    $expr
SQL
  write_geoname_lookup_from_sql "$file" ""
  cat >> "$file" <<SQL
WHERE $where_expr;
\$\$;

SQL
}

write_pg_build_location_functions() {
  local file="$1"
  local expr
  echo "DROP FUNCTION IF EXISTS $(pg_ident build_location_label)(integer, text, integer, integer, integer);" >> "$file"
  expr="$(location_label_expr locale_param include_continent include_iso_code include_emoji)"
  if [[ -n "$expr" ]]; then
    write_pg_build_location_function "$file" build_location_label_by_geoname_id "integer, text, integer, integer, integer" "geoname_id_param integer, locale_param text, include_continent integer, include_iso_code integer, include_emoji integer" "$expr"
  else
    cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident build_location_label_by_geoname_id)(integer, text, integer, integer, integer);

-- build_location_label_by_geoname_id was not generated because no configured output columns can be returned.

SQL
  fi
}

network_lookup_columns() {
  if [[ "$NETWORK_LOOKUP_COLUMNS_CACHE_READY" == "true" ]]; then
    [[ -n "$NETWORK_LOOKUP_COLUMNS_CACHE" ]] && printf '%s\n' "$NETWORK_LOOKUP_COLUMNS_CACHE"
    return
  fi
  local columns=(network)
  local version table col
  for version in "${IP_VERSIONS[@]}"; do
    table="ipv$version"
    while IFS= read -r col; do
      array_contains "$col" "${columns[@]}" || columns+=("$col")
    done < <(network_lookup_table_columns "$table")
  done
  NETWORK_LOOKUP_COLUMNS_CACHE="$(printf '%s\n' "${columns[@]}")"
  NETWORK_LOOKUP_COLUMNS_CACHE_READY=true
  printf '%s\n' "$NETWORK_LOOKUP_COLUMNS_CACHE"
}

network_lookup_table_columns() {
  local table="$1"
  local columns=(network)
  local col
  if is_location_family && column_enabled "$table" e_geoname_id; then
    columns+=(e_geoname_id e_geoname_source_code)
  fi
  while IFS= read -r col; do
    [[ -n "$col" && "$col" != "network" ]] || continue
    column_enabled "$table" "$col" || continue
    array_contains "$col" "${columns[@]}" || columns+=("$col")
  done < <(header_columns "$(block_csv_path "$table")")
  printf '%s\n' "${columns[@]}"
}

pg_network_lookup_type() {
  local col="$1"
  local type
  if [[ "$col" == "network" ]]; then
    printf 'cidr'
    return
  fi
  type="$(pg_type_block "$col")"
  type="${type/ DEFAULT NULL/}"
  printf '%s' "$type"
}

pg_network_lookup_return_cols_sql() {
  local cols=("$@")
  local return_cols="" col type
  for col in "${cols[@]}"; do
    type="$(pg_network_lookup_type "$col")"
    return_cols="${return_cols}${return_cols:+, }$(pg_ident "$col") $type"
  done
  printf '%s' "$return_cols"
}

block_table_has_output_column() {
  local table="$1"
  local wanted="$2"
  local cache_key status=1
  cache_key="${table}"$'\034'"${wanted}"
  if [[ -v 'BLOCK_TABLE_HAS_OUTPUT_COLUMN_CACHE[$cache_key]' ]]; then
    return "${BLOCK_TABLE_HAS_OUTPUT_COLUMN_CACHE[$cache_key]}"
  fi
  local col
  if [[ "$wanted" == "network" || "$wanted" == "start_ip" || "$wanted" == "last_ip" ]]; then
    if column_enabled "$table" "$wanted"; then status=0; fi
    BLOCK_TABLE_HAS_OUTPUT_COLUMN_CACHE[$cache_key]="$status"
    return "$status"
  fi
  if [[ "$wanted" == "e_geoname_id" || "$wanted" == "e_geoname_source_code" ]]; then
    if is_location_family && column_enabled "$table" "$wanted"; then status=0; fi
    BLOCK_TABLE_HAS_OUTPUT_COLUMN_CACHE[$cache_key]="$status"
    return "$status"
  fi
  while IFS= read -r col; do
    if [[ "$col" == "$wanted" ]]; then
      if column_enabled "$table" "$wanted"; then status=0; fi
      BLOCK_TABLE_HAS_OUTPUT_COLUMN_CACHE[$cache_key]="$status"
      return "$status"
    fi
  done < <(header_columns "$(block_csv_path "$table")")
  BLOCK_TABLE_HAS_OUTPUT_COLUMN_CACHE[$cache_key]="$status"
  return "$status"
}

network_lookup_inner_selects_sql() {
  local table="$1"
  shift
  local cols=("$@")
  local selects=()
  local col type
  for col in "${cols[@]}"; do
    if block_table_has_output_column "$table" "$col"; then
      selects+=("b.$(ident "$col") AS $(ident "$col")")
    elif [[ "$DBMS" == "postgresql" ]]; then
      type="$(pg_network_lookup_type "$col")"
      selects+=("NULL::$type AS $(ident "$col")")
    else
      selects+=("NULL AS $(ident "$col")")
    fi
  done
  selects+=("b.$(ident last_ip) AS $(ident __last_ip)")
  join_sql_items ", " "${selects[@]}"
}

network_lookup_outer_selects_sql() {
  local cols=("$@")
  local selects=()
  local col
  for col in "${cols[@]}"; do
    selects+=("candidate.$(ident "$col") AS $(ident "$col")")
  done
  join_sql_items ", " "${selects[@]}"
}

network_lookup_alias_selects_sql() {
  local alias="$1"
  shift
  local cols=("$@")
  local selects=()
  local col
  for col in "${cols[@]}"; do
    selects+=("$alias.$(ident "$col") AS $(ident "$col")")
  done
  join_sql_items ", " "${selects[@]}"
}

mysql_network_lookup_empty_select_sql() {
  local cols=("$@")
  local selects=()
  local col
  for col in "${cols[@]}"; do
    selects+=("NULL AS $(mysql_ident "$col")")
  done
  join_sql_items ", " "${selects[@]}"
}

pg_network_lookup_null_selects_sql() {
  local cols=("$@")
  local selects=()
  local col
  for col in "${cols[@]}"; do
    selects+=("NULL::$(pg_network_lookup_type "$col") AS $(pg_ident "$col")")
  done
  join_sql_items ", " "${selects[@]}"
}

mysql_network_lookup_temp_columns_sql() {
  local cols=("$@")
  local lines=(
    "        $(mysql_ident ord) INT UNSIGNED NOT NULL"
    "        $(mysql_ident ip) VARCHAR(45) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL"
    "        $(mysql_ident status) VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL"
    "        $(mysql_ident ip_version) TINYINT UNSIGNED DEFAULT NULL"
  )
  local col
  for col in "${cols[@]}"; do
    lines+=("        $(mysql_ident "$col") $(mysql_type_block "$col")")
  done
  lines+=("        PRIMARY KEY ($(mysql_ident ord))")
  join_sql_items $',\n' "${lines[@]}"
}

mysql_network_lookup_update_assignments_sql() {
  local cols=("$@")
  local sets=()
  local col
  for col in "${cols[@]}"; do
    sets+=("r.$(mysql_ident "$col") = candidate.$(mysql_ident "$col")")
  done
  join_sql_items $',\n                ' "${sets[@]}"
}

mysql_network_lookup_temp_engine_sql() {
  local cols=("$@")
  local col type
  for col in "${cols[@]}"; do
    type="$(mysql_type_block "$col")"
    if [[ "$type" == *TEXT* || "$type" == *BLOB* ]]; then
      echo "InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci"
      return
    fi
  done
  echo "MEMORY DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci"
}

write_mysql_network_lookup_branch() {
  local file="$1"
  local table="$2"
  local value_expr="$3"
  local ip_version="$4"
  shift 4
  local cols=("$@")
  local inner_selects outer_selects
  inner_selects="$(network_lookup_inner_selects_sql "$table" "${cols[@]}")"
  outer_selects="$(network_lookup_outer_selects_sql "${cols[@]}")"
  cat >> "$file" <<SQL
            SELECT CASE WHEN candidate.$(ident network) IS NULL THEN 'not_found' ELSE 'ok' END AS $(ident status),
                   ip AS $(ident ip),
                   $ip_version AS $(ident ip_version),
                   $outer_selects
            FROM (SELECT 1 AS $(ident seed)) AS seed
            LEFT JOIN (
                SELECT $inner_selects
                FROM $(ident "$table") b
                WHERE b.$(ident start_ip) <= $value_expr
                ORDER BY b.$(ident start_ip) DESC
                LIMIT 1
            ) AS candidate ON candidate.$(ident __last_ip) >= $value_expr;
SQL
}

write_mysql_network_lookup_procedure() {
  local file="$1"
  local definer="$2"
  local has4="$3"
  local has6="$4"
  local cols=()
  local empty_select
  mapfile -t cols < <(network_lookup_columns)
  empty_select="$(mysql_network_lookup_empty_select_sql "${cols[@]}")"
  cat >> "$file" <<SQL
DELIMITER \$\$
DROP PROCEDURE IF EXISTS $(mysql_ident find_network_by_ip)\$\$
CREATE ${definer}PROCEDURE $(mysql_ident find_network_by_ip)(ip VARCHAR(45))
    READS SQL DATA
BEGIN
SQL
  [[ "$has6" == "true" ]] && echo "    DECLARE ip6 DECIMAL(39,0) DEFAULT NULL;" >> "$file"
  [[ "$has4" == "true" ]] && echo "    DECLARE ip4 INT UNSIGNED DEFAULT NULL;" >> "$file"
  cat >> "$file" <<SQL
    IF IS_IPV6(ip) = 1 THEN
SQL
  if [[ "$has6" == "true" ]]; then
    cat >> "$file" <<SQL
        SET ip6 = $(mysql_ident inet6_aton_decimal)(ip);
SQL
    write_mysql_network_lookup_branch "$file" ipv6 ip6 6 "${cols[@]}"
  else
    cat >> "$file" <<SQL
        SELECT 'not_found' AS $(ident status), ip AS $(ident ip), 6 AS $(ident ip_version), $empty_select;
SQL
  fi
  cat >> "$file" <<SQL
    ELSEIF IS_IPV4(ip) = 1 THEN
SQL
  if [[ "$has4" == "true" ]]; then
    cat >> "$file" <<SQL
        SET ip4 = INET_ATON(ip);
SQL
    write_mysql_network_lookup_branch "$file" ipv4 ip4 4 "${cols[@]}"
  else
    cat >> "$file" <<SQL
        SELECT 'not_found' AS $(ident status), ip AS $(ident ip), 4 AS $(ident ip_version), $empty_select;
SQL
  fi
  cat >> "$file" <<SQL
    ELSE
        SELECT 'invalid_ip' AS $(ident status), ip AS $(ident ip), NULL AS $(ident ip_version), $empty_select;
    END IF;
END\$\$
DELIMITER ;

SQL
}

write_pg_network_lookup_branch() {
  local file="$1"
  local table="$2"
  shift 2
  local cols=("$@")
  local inner_selects outer_selects
  if [[ "${#cols[@]}" -eq 0 ]]; then
    mapfile -t cols < <(network_lookup_columns)
  fi
  inner_selects="$(network_lookup_inner_selects_sql "$table" "${cols[@]}")"
  outer_selects="$(network_lookup_outer_selects_sql "${cols[@]}")"
  cat >> "$file" <<SQL
        RETURN QUERY
        SELECT $outer_selects
        FROM (
            SELECT $inner_selects
            FROM $(ident "$table") b
            WHERE b.$(ident start_ip) <= v_ip
            ORDER BY b.$(ident start_ip) DESC
            LIMIT 1
        ) AS candidate
        WHERE candidate.$(ident __last_ip) >= v_ip;
        RETURN;
SQL
}

write_pg_network_status_lookup_branch() {
  local file="$1"
  local table="$2"
  local family="$3"
  shift 3
  local cols=("$@")
  local inner_selects outer_selects
  inner_selects="$(network_lookup_inner_selects_sql "$table" "${cols[@]}")"
  outer_selects="$(network_lookup_outer_selects_sql "${cols[@]}")"
  cat >> "$file" <<SQL
        RETURN QUERY
        SELECT 'ok'::text, p_ip, $family, $outer_selects
        FROM (
            SELECT $inner_selects
            FROM $(ident "$table") b
            WHERE b.$(ident start_ip) <= v_ip
            ORDER BY b.$(ident start_ip) DESC
            LIMIT 1
        ) AS candidate
        WHERE candidate.$(ident __last_ip) >= v_ip;
        IF FOUND THEN
            RETURN;
        END IF;
SQL
}

write_pg_network_lookup_function() {
  local file="$1"
  local has4="$2"
  local has6="$3"
  local cols=()
  local return_cols null_selects
  mapfile -t cols < <(network_lookup_columns)
  return_cols="$(pg_ident status) text, $(pg_ident ip) text, $(pg_ident ip_version) integer, $(pg_network_lookup_return_cols_sql "${cols[@]}")"
  null_selects="$(pg_network_lookup_null_selects_sql "${cols[@]}")"
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident find_network_by_ip)(text);

CREATE OR REPLACE FUNCTION $(pg_ident find_network_by_ip)(p_ip text)
RETURNS TABLE($return_cols)
LANGUAGE plpgsql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
DECLARE
    v_ip inet;
BEGIN
    IF p_ip IS NULL OR position('/' in p_ip) > 0 OR NOT pg_input_is_valid(p_ip, 'inet') THEN
        RETURN QUERY SELECT 'invalid_ip'::text, p_ip, NULL::integer, $null_selects;
        RETURN;
    END IF;
    v_ip := p_ip::inet;
SQL
  if [[ "$has4" == "true" ]]; then
    cat >> "$file" <<SQL
    IF family(v_ip) = 4 THEN
SQL
    write_pg_network_status_lookup_branch "$file" ipv4 4 "${cols[@]}"
    cat >> "$file" <<SQL
    END IF;
SQL
  fi
  if [[ "$has6" == "true" ]]; then
    cat >> "$file" <<SQL
    IF family(v_ip) = 6 THEN
SQL
    write_pg_network_status_lookup_branch "$file" ipv6 6 "${cols[@]}"
    cat >> "$file" <<SQL
    END IF;
SQL
  fi
  cat >> "$file" <<SQL
    RETURN QUERY SELECT 'not_found'::text, p_ip, family(v_ip), $null_selects;
    RETURN;
END;
\$\$;

SQL
}

write_pg_network_lookup_family_function() {
  local file="$1"
  local name="$2"
  local table="$3"
  local family="$4"
  local cols=()
  local return_cols
  mapfile -t cols < <(network_lookup_table_columns "$table")
  return_cols="$(pg_network_lookup_return_cols_sql "${cols[@]}")"
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident "$name")(text);

CREATE OR REPLACE FUNCTION $(pg_ident "$name")(p_ip text)
RETURNS TABLE($return_cols)
LANGUAGE plpgsql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
DECLARE
    v_ip inet;
BEGIN
    IF p_ip IS NULL OR position('/' in p_ip) > 0 OR NOT pg_input_is_valid(p_ip, 'inet') THEN
        RETURN;
    END IF;
    v_ip := p_ip::inet;
    IF family(v_ip) <> $family THEN
        RETURN;
    END IF;
SQL
  write_pg_network_lookup_branch "$file" "$table" "${cols[@]}"
  cat >> "$file" <<SQL
END;
\$\$;

SQL
}

write_pg_network_lookup_family_functions() {
  local file="$1"
  local has4="$2"
  local has6="$3"
  if [[ "$has4" == "true" ]]; then
    write_pg_network_lookup_family_function "$file" find_ipv4_network_by_ip ipv4 4
  else
    echo "DROP FUNCTION IF EXISTS $(pg_ident find_ipv4_network_by_ip)(text);" >> "$file"
    echo >> "$file"
  fi
  if [[ "$has6" == "true" ]]; then
    write_pg_network_lookup_family_function "$file" find_ipv6_network_by_ip ipv6 6
  else
    echo "DROP FUNCTION IF EXISTS $(pg_ident find_ipv6_network_by_ip)(text);" >> "$file"
    echo >> "$file"
  fi
}

write_mysql_network_lookup_batch_update_branch() {
  local file="$1"
  local table="$2"
  local value_var="$3"
  shift 3
  local cols=("$@")
  local inner_selects update_assignments
  inner_selects="$(network_lookup_inner_selects_sql "$table" "${cols[@]}")"
  update_assignments="$(mysql_network_lookup_update_assignments_sql "${cols[@]}")"
  cat >> "$file" <<SQL
            UPDATE $(mysql_ident _find_networks_by_ips_json_result) r
            JOIN (
                SELECT $inner_selects
                FROM $(ident "$table") b
                WHERE b.$(ident start_ip) <= $value_var
                ORDER BY b.$(ident start_ip) DESC
                LIMIT 1
            ) AS candidate ON candidate.$(ident __last_ip) >= $value_var
            SET r.$(mysql_ident status) = 'ok',
                $update_assignments
            WHERE r.$(ident ord) = v_ord;
SQL
}

write_mysql_network_lookup_batch_body() {
  local file="$1"
  local branch_has4="$2"
  local branch_has6="$3"
  shift 3
  local cols=("$@")
  local batch_selects temp_columns temp_engine
  batch_selects="$(network_lookup_alias_selects_sql r "${cols[@]}")"
  temp_columns="$(mysql_network_lookup_temp_columns_sql "${cols[@]}")"
  temp_engine="$(mysql_network_lookup_temp_engine_sql "${cols[@]}")"
  cat >> "$file" <<SQL
    DROP TEMPORARY TABLE IF EXISTS $(mysql_ident _find_networks_by_ips_json_result);
    CREATE TEMPORARY TABLE $(mysql_ident _find_networks_by_ips_json_result) (
$temp_columns
    ) ENGINE=$temp_engine;

    SET idx = LEAST(item_count, (page_param - 1) * per_page_param);
    SET item_count = LEAST(item_count, idx + per_page_param);
    WHILE idx < item_count DO
        SET v_ord = idx + 1;
        SET v_item = JSON_EXTRACT(ips_json, CONCAT('\$[', idx, ']'));
        SET v_ip = CASE WHEN JSON_TYPE(v_item) = 'STRING' THEN JSON_UNQUOTE(v_item) ELSE NULL END;
        SET v_ip4 = NULL;
        SET v_ip6 = NULL;

        INSERT INTO $(mysql_ident _find_networks_by_ips_json_result)
            ($(ident ord), $(ident ip), $(ident status), $(ident ip_version))
        VALUES (v_ord, v_ip, 'invalid_ip', NULL);

        IF v_ip IS NOT NULL AND IS_IPV6(v_ip) = 1 THEN
            UPDATE $(mysql_ident _find_networks_by_ips_json_result)
            SET $(ident status) = 'not_found', $(ident ip_version) = 6
            WHERE $(ident ord) = v_ord;
            SET v_ip6 = $(mysql_ident inet6_aton_decimal)(v_ip);
SQL
  if [[ "$branch_has6" == "true" ]]; then
    write_mysql_network_lookup_batch_update_branch "$file" ipv6 v_ip6 "${cols[@]}"
  fi
  cat >> "$file" <<SQL
        ELSEIF v_ip IS NOT NULL AND IS_IPV4(v_ip) = 1 THEN
            UPDATE $(mysql_ident _find_networks_by_ips_json_result)
            SET $(ident status) = 'not_found', $(ident ip_version) = 4
            WHERE $(ident ord) = v_ord;
            SET v_ip4 = INET_ATON(v_ip);
SQL
  if [[ "$branch_has4" == "true" ]]; then
    write_mysql_network_lookup_batch_update_branch "$file" ipv4 v_ip4 "${cols[@]}"
  fi
  cat >> "$file" <<SQL
        END IF;

        SET idx = idx + 1;
    END WHILE;

    SELECT r.$(ident ord) AS $(ident ord), v_total_count AS $(ident total_count), r.$(ident ip) AS $(ident ip),
           r.$(ident status) AS $(ident status), r.$(ident ip_version) AS $(ident ip_version),
           $batch_selects
    FROM $(mysql_ident _find_networks_by_ips_json_result) r
    ORDER BY r.$(ident ord);

    DROP TEMPORARY TABLE IF EXISTS $(mysql_ident _find_networks_by_ips_json_result);
SQL
}

write_mysql_network_lookup_batch_procedure() {
  local file="$1"
  local definer="$2"
  local has4="$3"
  local has6="$4"
  local cols=()
  mapfile -t cols < <(network_lookup_columns)
  cat >> "$file" <<SQL
DELIMITER \$\$
DROP PROCEDURE IF EXISTS $(mysql_ident find_networks_by_ips_json)\$\$
DROP PROCEDURE IF EXISTS $(mysql_ident find_networks_by_json_ips)\$\$
CREATE ${definer}PROCEDURE $(mysql_ident find_networks_by_json_ips)(ips_json JSON, page_param BIGINT UNSIGNED, per_page_param BIGINT UNSIGNED)
    READS SQL DATA
BEGIN
    DECLARE idx INT UNSIGNED DEFAULT 0;
    DECLARE item_count INT UNSIGNED DEFAULT 0;
    DECLARE v_total_count INT UNSIGNED DEFAULT 0;
    DECLARE v_ord INT UNSIGNED DEFAULT 0;
    DECLARE v_item JSON DEFAULT NULL;
    DECLARE v_ip VARCHAR(45) DEFAULT NULL;
    DECLARE v_ip4 INT UNSIGNED DEFAULT NULL;
    DECLARE v_ip6 DECIMAL(39,0) DEFAULT NULL;

    IF ips_json IS NULL OR JSON_TYPE(ips_json) <> 'ARRAY' THEN
        SIGNAL SQLSTATE '22032' SET MESSAGE_TEXT = 'ips_json must be a JSON array';
    END IF;
    IF page_param IS NULL OR page_param < 1 THEN
        SIGNAL SQLSTATE '22023' SET MESSAGE_TEXT = 'page must be greater than or equal to 1';
    END IF;
    IF per_page_param IS NULL OR per_page_param < 1 THEN
        SIGNAL SQLSTATE '22023' SET MESSAGE_TEXT = 'per_page must be greater than or equal to 1';
    END IF;
    SET v_total_count = COALESCE(JSON_LENGTH(ips_json), 0);
    SET item_count = v_total_count;

SQL
  write_mysql_network_lookup_batch_body "$file" "$has4" "$has6" "${cols[@]}"
  cat >> "$file" <<SQL
END\$\$
DELIMITER ;

SQL
}

write_pg_batch_page_offset_function() {
  local file="$1"
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident _batch_page_offset)(integer);
DROP FUNCTION IF EXISTS $(pg_ident _batch_page_offset)(integer, integer);

CREATE OR REPLACE FUNCTION $(pg_ident _batch_page_offset)(p_page integer, p_per_page integer)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
$(pg_routine_search_path_clause)
AS \$\$
BEGIN
    IF p_page IS NULL OR p_page < 1 THEN
        RAISE EXCEPTION 'page must be greater than or equal to 1' USING ERRCODE = '22023';
    END IF;
    IF p_per_page IS NULL OR p_per_page < 1 THEN
        RAISE EXCEPTION 'per_page must be greater than or equal to 1' USING ERRCODE = '22023';
    END IF;
    RETURN (p_page::bigint - 1) * p_per_page::bigint;
END;
\$\$;

SQL
}

write_pg_routine_precleanup() {
  local file="$1"
  cat >> "$file" <<SQL
-- Drop generated wrappers before replacing routines they depend on.
DROP FUNCTION IF EXISTS $(pg_ident build_location_labels_by_ip)(text, jsonb, integer, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident build_location_labels_by_json_geoname_ids)(jsonb, text, integer, integer, integer, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident build_location_labels_by_geoname_ids_json)(jsonb, text, integer, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident build_location_labels_by_geoname_ids_json)(jsonb, text, integer, integer, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_json_ips)(jsonb, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_json_geoname_ids)(jsonb, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_json_ips)(jsonb, integer, integer, integer, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_json_geoname_ids)(jsonb, integer, integer, integer, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_ip)(text);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_ips_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_ips_json)(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_geoname_ids_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_geoname_ids_json)(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_e_geoname_ids_by_json_ips)(jsonb, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_effective_geoname_ids_by_ips_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_effective_geoname_ids_by_ips_json)(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoname_ids_by_json_ips)(jsonb, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_ip_geoname_ids_by_ips_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_ip_geoname_ids_by_ips_json)(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoname_ids_by_ip)(text);
DROP FUNCTION IF EXISTS $(pg_ident find_ip_geoname_ids_by_ip)(text);
DROP FUNCTION IF EXISTS $(pg_ident find_ipv4_networks_by_json_ips)(jsonb, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_ipv6_networks_by_json_ips)(jsonb, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_networks_by_json_ips)(jsonb, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_ipv4_networks_by_ips_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_ipv4_networks_by_ips_json)(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_ipv6_networks_by_ips_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_ipv6_networks_by_ips_json)(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_networks_by_ips_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_networks_by_ips_json)(jsonb, integer);

SQL
}

write_pg_network_lookup_batch_lateral_branch() {
  local file="$1"
  local table="$2"
  local family="$3"
  shift 3
  local cols=("$@")
  local inner_selects outer_selects
  inner_selects="$(network_lookup_inner_selects_sql "$table" "${cols[@]}")"
  outer_selects="$(network_lookup_outer_selects_sql "${cols[@]}")"
  cat >> "$file" <<SQL
    SELECT $outer_selects
    FROM (
        SELECT $inner_selects
        FROM $(ident "$table") b
        WHERE family(i.$(ident parsed_ip)) = $family
          AND b.$(ident start_ip) <= i.$(ident parsed_ip)
        ORDER BY b.$(ident start_ip) DESC
        LIMIT 1
    ) AS candidate
    WHERE candidate.$(ident __last_ip) >= i.$(ident parsed_ip)
SQL
}

write_pg_network_lookup_batch_function_named() {
  local file="$1"
  local name="$2"
  local has4="$3"
  local has6="$4"
  shift 4
  local cols=("$@")
  local return_cols batch_selects wrote_branch=false
  return_cols="$(pg_ident ord) integer, $(pg_ident total_count) bigint, $(pg_ident ip) text, $(pg_ident status) text, $(pg_ident ip_version) integer"
  return_cols="${return_cols}, $(pg_network_lookup_return_cols_sql "${cols[@]}")"
  batch_selects="$(network_lookup_alias_selects_sql c "${cols[@]}")"
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident "$name")(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident "$name")(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident "$name")(jsonb, integer, integer);

CREATE OR REPLACE FUNCTION $(pg_ident "$name")(p_ips jsonb, p_page integer, p_per_page integer)
RETURNS TABLE($return_cols)
LANGUAGE sql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
WITH raw_input AS (
    SELECT item.$(ident ord)::integer AS $(ident ord),
           jsonb_array_length(p_ips)::bigint AS $(ident total_count),
           CASE WHEN jsonb_typeof(item.$(ident value)) = 'string' THEN item.$(ident value) #>> '{}' ELSE NULL END AS $(ident ip)
    FROM jsonb_array_elements(COALESCE(p_ips, 'null'::jsonb)) WITH ORDINALITY AS item($(ident value), $(ident ord))
    ORDER BY item.$(ident ord)
    LIMIT p_per_page OFFSET $(pg_ident _batch_page_offset)(p_page, p_per_page)
), input AS (
    SELECT r.$(ident ord), r.$(ident total_count), r.$(ident ip),
           CASE
             WHEN r.$(ident ip) IS NOT NULL
              AND position('/' in r.$(ident ip)) = 0
              AND pg_input_is_valid(r.$(ident ip), 'inet')
             THEN r.$(ident ip)::inet
             ELSE NULL
           END AS $(ident parsed_ip)
    FROM raw_input r
)
SELECT i.$(ident ord), i.$(ident total_count), i.$(ident ip),
       CASE WHEN i.$(ident parsed_ip) IS NULL THEN 'invalid_ip'
            WHEN c.$(ident network) IS NULL THEN 'not_found'
            ELSE 'ok' END AS $(ident status),
       CASE WHEN i.$(ident parsed_ip) IS NULL THEN NULL ELSE family(i.$(ident parsed_ip)) END AS $(ident ip_version),
       $batch_selects
FROM input i
LEFT JOIN LATERAL (
SQL
  if [[ "$has4" == "true" ]]; then
    write_pg_network_lookup_batch_lateral_branch "$file" ipv4 4 "${cols[@]}"
    wrote_branch=true
  fi
  if [[ "$has6" == "true" ]]; then
    [[ "$wrote_branch" == "true" ]] && echo "    UNION ALL" >> "$file"
    write_pg_network_lookup_batch_lateral_branch "$file" ipv6 6 "${cols[@]}"
  fi
  cat >> "$file" <<SQL
 ) c ON TRUE
ORDER BY i.$(ident ord);
\$\$;

SQL
}

write_pg_network_lookup_batch_function() {
  local file="$1"
  local has4="$2"
  local has6="$3"
  local cols=()
  mapfile -t cols < <(network_lookup_columns)
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident find_networks_by_ips_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_networks_by_ips_json)(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_networks_by_ips_json)(jsonb, integer, integer);

SQL
  write_pg_network_lookup_batch_function_named "$file" find_networks_by_json_ips "$has4" "$has6" "${cols[@]}"
}

write_pg_network_lookup_batch_family_functions() {
  local file="$1"
  local has4="$2"
  local has6="$3"
  local cols4=() cols6=()
  if [[ "$has4" == "true" ]]; then
    mapfile -t cols4 < <(network_lookup_table_columns ipv4)
    cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident find_ipv4_networks_by_ips_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_ipv4_networks_by_ips_json)(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_ipv4_networks_by_ips_json)(jsonb, integer, integer);

SQL
    write_pg_network_lookup_batch_function_named "$file" find_ipv4_networks_by_json_ips true false "${cols4[@]}"
  else
    echo "DROP FUNCTION IF EXISTS $(pg_ident find_ipv4_networks_by_ips_json)(jsonb);" >> "$file"
    echo "DROP FUNCTION IF EXISTS $(pg_ident find_ipv4_networks_by_ips_json)(jsonb, integer);" >> "$file"
    echo "DROP FUNCTION IF EXISTS $(pg_ident find_ipv4_networks_by_json_ips)(jsonb, integer, integer);" >> "$file"
    echo >> "$file"
  fi
  if [[ "$has6" == "true" ]]; then
    mapfile -t cols6 < <(network_lookup_table_columns ipv6)
    cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident find_ipv6_networks_by_ips_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_ipv6_networks_by_ips_json)(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_ipv6_networks_by_ips_json)(jsonb, integer, integer);

SQL
    write_pg_network_lookup_batch_function_named "$file" find_ipv6_networks_by_json_ips false true "${cols6[@]}"
  else
    echo "DROP FUNCTION IF EXISTS $(pg_ident find_ipv6_networks_by_ips_json)(jsonb);" >> "$file"
    echo "DROP FUNCTION IF EXISTS $(pg_ident find_ipv6_networks_by_ips_json)(jsonb, integer);" >> "$file"
    echo "DROP FUNCTION IF EXISTS $(pg_ident find_ipv6_networks_by_json_ips)(jsonb, integer, integer);" >> "$file"
    echo >> "$file"
  fi
}

effective_geoname_source_expr() {
  local alias="$1"
  printf "CASE %s.%s WHEN 1 THEN 'geoname_id' WHEN 2 THEN 'registered_country_geoname_id' WHEN 3 THEN 'represented_country_geoname_id' ELSE NULL END" "$alias" "$(ident e_geoname_source_code)"
}

geoname_role_label_column() {
  case "$1" in
    geoname_id) printf 'geoname_label' ;;
    registered_country_geoname_id) printf 'registered_country_label' ;;
    represented_country_geoname_id) printf 'represented_country_label' ;;
    *) die "Unsupported GeoName role column: $1" ;;
  esac
}

write_mysql_ip_geoname_lookup_branch() {
  local file="$1"
  local table="$2"
  local value_expr="$3"
  local ip_version="$4"
  local role outer_role_selects="" inner_role_selects=""
  local roles=()
  mapfile -t roles < <(enabled_geoname_role_columns)
  for role in "${roles[@]}"; do
    outer_role_selects+=$',\n'"               candidate.$(ident "$role") AS $(ident "$role")"
    if column_enabled "$table" "$role"; then
      inner_role_selects+=$',\n'"                   b.$(ident "$role") AS $(ident "$role")"
    else
      inner_role_selects+=$',\n'"                   NULL AS $(ident "$role")"
    fi
  done
  cat >> "$file" <<SQL
        SELECT CASE WHEN candidate.$(ident network) IS NULL THEN 'not_found'
                    WHEN candidate.$(ident e_geoname_id) IS NULL THEN 'no_location'
                    ELSE 'ok' END AS $(ident status),
               ip AS $(ident ip), $ip_version AS $(ident ip_version), candidate.$(ident network) AS $(ident network),
               candidate.$(ident e_geoname_id) AS $(ident e_geoname_id),
               $(effective_geoname_source_expr candidate) AS $(ident e_geoname_source)$outer_role_selects
        FROM (SELECT 1 AS $(ident seed)) AS seed
        LEFT JOIN (
            SELECT b.$(ident network), b.$(ident e_geoname_id), b.$(ident e_geoname_source_code)$inner_role_selects,
                   b.$(ident last_ip) AS $(ident __last_ip)
            FROM $(ident "$table") b
            WHERE b.$(ident start_ip) <= $value_expr
            ORDER BY b.$(ident start_ip) DESC
            LIMIT 1
        ) candidate ON candidate.$(ident __last_ip) >= $value_expr;
SQL
}

write_mysql_ip_geoname_lookup_procedure() {
  local file="$1"
  local definer="$2"
  local has4="$3"
  local has6="$4"
  local role null_role_selects=""
  local roles=()
  mapfile -t roles < <(enabled_geoname_role_columns)
  for role in "${roles[@]}"; do
    null_role_selects+=$',\n'"               NULL AS $(ident "$role")"
  done
  cat >> "$file" <<SQL
DELIMITER \$\$
DROP PROCEDURE IF EXISTS $(mysql_ident find_ip_geoname_ids_by_ip)\$\$
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoname_ids_by_ip)\$\$
CREATE ${definer}PROCEDURE $(mysql_ident find_geoname_ids_by_ip)(ip VARCHAR(45))
    READS SQL DATA
    SQL SECURITY INVOKER
BEGIN
SQL
  [[ "$has6" == "true" ]] && echo "    DECLARE ip6 DECIMAL(39,0) DEFAULT NULL;" >> "$file"
  [[ "$has4" == "true" ]] && echo "    DECLARE ip4 INT UNSIGNED DEFAULT NULL;" >> "$file"
  cat >> "$file" <<SQL
    IF IS_IPV6(ip) = 1 THEN
SQL
  if [[ "$has6" == "true" ]]; then
    echo "        SET ip6 = $(mysql_ident inet6_aton_decimal)(ip);" >> "$file"
    write_mysql_ip_geoname_lookup_branch "$file" ipv6 ip6 6
  else
    cat >> "$file" <<SQL
        SELECT 'not_found' AS $(ident status), ip AS $(ident ip), 6 AS $(ident ip_version),
               NULL AS $(ident network), NULL AS $(ident e_geoname_id), NULL AS $(ident e_geoname_source)$null_role_selects;
SQL
  fi
  cat >> "$file" <<SQL
    ELSEIF IS_IPV4(ip) = 1 THEN
SQL
  if [[ "$has4" == "true" ]]; then
    echo "        SET ip4 = INET_ATON(ip);" >> "$file"
    write_mysql_ip_geoname_lookup_branch "$file" ipv4 ip4 4
  else
    cat >> "$file" <<SQL
        SELECT 'not_found' AS $(ident status), ip AS $(ident ip), 4 AS $(ident ip_version),
               NULL AS $(ident network), NULL AS $(ident e_geoname_id), NULL AS $(ident e_geoname_source)$null_role_selects;
SQL
  fi
  cat >> "$file" <<SQL
    ELSE
        SELECT 'invalid_ip' AS $(ident status), ip AS $(ident ip), NULL AS $(ident ip_version),
               NULL AS $(ident network), NULL AS $(ident e_geoname_id), NULL AS $(ident e_geoname_source)$null_role_selects;
    END IF;
END\$\$
DELIMITER ;

SQL
}

write_mysql_ip_geoname_batch_update_branch() {
  local file="$1"
  local table="$2"
  local value_var="$3"
  shift 3
  local roles=("$@")
  local role inner_role_selects="" set_role_values=""
  for role in "${roles[@]}"; do
    if column_enabled "$table" "$role"; then
      inner_role_selects+=$',\n'"                       b.$(ident "$role") AS $(ident "$role")"
    else
      inner_role_selects+=$',\n'"                       NULL AS $(ident "$role")"
    fi
    set_role_values+=$',\n'"                 r.$(ident "$role") = candidate.$(ident "$role")"
  done
  cat >> "$file" <<SQL
            UPDATE $(mysql_ident _find_ip_geoname_ids_result) r
            JOIN (
                SELECT b.$(ident network), b.$(ident e_geoname_id), b.$(ident e_geoname_source_code)$inner_role_selects,
                       b.$(ident last_ip) AS $(ident __last_ip)
                FROM $(ident "$table") b
                WHERE b.$(ident start_ip) <= $value_var
                ORDER BY b.$(ident start_ip) DESC
                LIMIT 1
            ) candidate ON candidate.$(ident __last_ip) >= $value_var
            SET r.$(ident status) = CASE WHEN candidate.$(ident e_geoname_id) IS NULL THEN 'no_location' ELSE 'ok' END,
                r.$(ident network) = candidate.$(ident network),
                r.$(ident e_geoname_id) = candidate.$(ident e_geoname_id),
                r.$(ident e_geoname_source_code) = candidate.$(ident e_geoname_source_code)$set_role_values
            WHERE r.$(ident ord) = v_ord;
SQL
}

write_mysql_ip_geoname_lookup_batch_procedure() {
  local file="$1"
  local definer="$2"
  local has4="$3"
  local has6="$4"
  local role output_role_selects=""
  local roles=()
  mapfile -t roles < <(enabled_geoname_role_columns)
  for role in "${roles[@]}"; do
    output_role_selects+=$',\n'"           r.$(ident "$role") AS $(ident "$role")"
  done
  cat >> "$file" <<SQL
DELIMITER \$\$
DROP PROCEDURE IF EXISTS $(mysql_ident find_ip_geoname_ids_by_ips_json)\$\$
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoname_ids_by_json_ips)\$\$
CREATE ${definer}PROCEDURE $(mysql_ident find_geoname_ids_by_json_ips)(ips_json JSON, page_param BIGINT UNSIGNED, per_page_param BIGINT UNSIGNED)
    READS SQL DATA
    SQL SECURITY INVOKER
BEGIN
    DECLARE idx INT UNSIGNED DEFAULT 0;
    DECLARE item_count INT UNSIGNED DEFAULT 0;
    DECLARE v_total_count INT UNSIGNED DEFAULT 0;
    DECLARE v_ord INT UNSIGNED DEFAULT 0;
    DECLARE v_item JSON DEFAULT NULL;
    DECLARE v_ip VARCHAR(45) DEFAULT NULL;
    DECLARE v_ip4 INT UNSIGNED DEFAULT NULL;
    DECLARE v_ip6 DECIMAL(39,0) DEFAULT NULL;

    IF ips_json IS NULL OR JSON_TYPE(ips_json) <> 'ARRAY' THEN
        SIGNAL SQLSTATE '22032' SET MESSAGE_TEXT = 'ips_json must be a JSON array';
    END IF;
    IF page_param IS NULL OR page_param < 1 THEN
        SIGNAL SQLSTATE '22023' SET MESSAGE_TEXT = 'page must be greater than or equal to 1';
    END IF;
    IF per_page_param IS NULL OR per_page_param < 1 THEN
        SIGNAL SQLSTATE '22023' SET MESSAGE_TEXT = 'per_page must be greater than or equal to 1';
    END IF;
    SET v_total_count = COALESCE(JSON_LENGTH(ips_json), 0);
    SET item_count = v_total_count;
    SET idx = LEAST(item_count, (page_param - 1) * per_page_param);
    SET item_count = LEAST(item_count, idx + per_page_param);

    DROP TEMPORARY TABLE IF EXISTS $(mysql_ident _find_ip_geoname_ids_result);
    CREATE TEMPORARY TABLE $(mysql_ident _find_ip_geoname_ids_result) (
        $(ident ord) INT UNSIGNED NOT NULL,
        $(ident ip) VARCHAR(45) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
        $(ident status) VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        $(ident ip_version) TINYINT UNSIGNED DEFAULT NULL,
        $(ident network) VARCHAR(43) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
        $(ident e_geoname_id) INT UNSIGNED DEFAULT NULL,
        $(ident e_geoname_source_code) TINYINT UNSIGNED DEFAULT NULL,
SQL
  for role in "${roles[@]}"; do
    echo "        $(ident "$role") INT UNSIGNED DEFAULT NULL," >> "$file"
  done
  cat >> "$file" <<SQL
        PRIMARY KEY ($(ident ord))
    ) ENGINE=MEMORY DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

    WHILE idx < item_count DO
        SET v_ord = idx + 1;
        SET v_item = JSON_EXTRACT(ips_json, CONCAT('\$[', idx, ']'));
        SET v_ip = CASE WHEN JSON_TYPE(v_item) = 'STRING' THEN JSON_UNQUOTE(v_item) ELSE NULL END;
        SET v_ip4 = NULL;
        SET v_ip6 = NULL;
        INSERT INTO $(mysql_ident _find_ip_geoname_ids_result) ($(ident ord), $(ident ip), $(ident status))
        VALUES (v_ord, v_ip, 'invalid_ip');

        IF v_ip IS NOT NULL AND IS_IPV6(v_ip) = 1 THEN
            UPDATE $(mysql_ident _find_ip_geoname_ids_result) SET $(ident status) = 'not_found', $(ident ip_version) = 6 WHERE $(ident ord) = v_ord;
            SET v_ip6 = $(mysql_ident inet6_aton_decimal)(v_ip);
SQL
  [[ "$has6" == "true" ]] && write_mysql_ip_geoname_batch_update_branch "$file" ipv6 v_ip6 "${roles[@]}"
  cat >> "$file" <<SQL
        ELSEIF v_ip IS NOT NULL AND IS_IPV4(v_ip) = 1 THEN
            UPDATE $(mysql_ident _find_ip_geoname_ids_result) SET $(ident status) = 'not_found', $(ident ip_version) = 4 WHERE $(ident ord) = v_ord;
            SET v_ip4 = INET_ATON(v_ip);
SQL
  [[ "$has4" == "true" ]] && write_mysql_ip_geoname_batch_update_branch "$file" ipv4 v_ip4 "${roles[@]}"
  cat >> "$file" <<SQL
        END IF;
        SET idx = idx + 1;
    END WHILE;

    SELECT r.$(ident ord), v_total_count AS $(ident total_count), r.$(ident ip), r.$(ident status), r.$(ident ip_version), r.$(ident network),
           r.$(ident e_geoname_id) AS $(ident e_geoname_id),
           $(effective_geoname_source_expr r) AS $(ident e_geoname_source)$output_role_selects
    FROM $(mysql_ident _find_ip_geoname_ids_result) r
    ORDER BY r.$(ident ord);

    DROP TEMPORARY TABLE IF EXISTS $(mysql_ident _find_ip_geoname_ids_result);
END\$\$
DELIMITER ;

SQL
}

write_pg_ip_geoname_lookup_functions() {
  local file="$1"
  local role return_role_columns="" select_role_columns=""
  local roles=()
  mapfile -t roles < <(enabled_geoname_role_columns)
  for role in "${roles[@]}"; do
    return_role_columns+=$',\n'"    $(ident "$role") integer"
    select_role_columns+=$',\n'"       n.$(ident "$role") AS $(ident "$role")"
  done
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident find_ip_geoname_ids_by_ip)(text);
DROP FUNCTION IF EXISTS $(pg_ident find_geoname_ids_by_ip)(text);

CREATE OR REPLACE FUNCTION $(pg_ident find_geoname_ids_by_ip)(p_ip text)
RETURNS TABLE(
    $(ident status) text, $(ident ip) text, $(ident ip_version) integer, $(ident network) cidr,
    $(ident e_geoname_id) integer, $(ident e_geoname_source) text$return_role_columns
)
LANGUAGE sql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
SELECT CASE WHEN n.$(ident status) = 'ok' AND n.$(ident e_geoname_id) IS NULL
            THEN 'no_location' ELSE n.$(ident status) END AS $(ident status),
       n.$(ident ip), n.$(ident ip_version), n.$(ident network),
       n.$(ident e_geoname_id) AS $(ident e_geoname_id),
       $(effective_geoname_source_expr n) AS $(ident e_geoname_source)$select_role_columns
FROM $(pg_ident find_network_by_ip)(p_ip) n;
\$\$;

DROP FUNCTION IF EXISTS $(pg_ident find_ip_geoname_ids_by_ips_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_ip_geoname_ids_by_ips_json)(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoname_ids_by_json_ips)(jsonb, integer, integer);

CREATE OR REPLACE FUNCTION $(pg_ident find_geoname_ids_by_json_ips)(p_ips jsonb, p_page integer, p_per_page integer)
RETURNS TABLE(
    $(ident ord) integer, $(ident total_count) bigint, $(ident ip) text, $(ident status) text, $(ident ip_version) integer, $(ident network) cidr,
    $(ident e_geoname_id) integer, $(ident e_geoname_source) text$return_role_columns
)
LANGUAGE sql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
SELECT n.$(ident ord), n.$(ident total_count), n.$(ident ip),
       CASE WHEN n.$(ident status) = 'ok' AND n.$(ident e_geoname_id) IS NULL
            THEN 'no_location' ELSE n.$(ident status) END AS $(ident status),
       n.$(ident ip_version), n.$(ident network),
       n.$(ident e_geoname_id) AS $(ident e_geoname_id),
       $(effective_geoname_source_expr n) AS $(ident e_geoname_source)$select_role_columns
FROM $(pg_ident find_networks_by_json_ips)(p_ips, p_page, p_per_page) n
ORDER BY n.$(ident ord);
\$\$;

SQL
}

write_mysql_batch_geoinfo_select_columns() {
  local file="$1"
  local include_ip="$2"
  local -n names_ref="$3"
  local -n exprs_ref="$4"
  local i
  echo "    SELECT" >> "$file"
  echo "        i.$(mysql_ident ord) AS $(mysql_ident ord)" >> "$file"
  echo "        , i.$(mysql_ident total_count) AS $(mysql_ident total_count)" >> "$file"
  if [[ "$include_ip" == "true" ]]; then
    echo "        , i.$(mysql_ident ip) AS $(mysql_ident ip)" >> "$file"
  fi
  echo "        , i.$(mysql_ident geoname_id) AS $(mysql_ident geoname_id)" >> "$file"
  for ((i = 0; i < ${#names_ref[@]}; i++)); do
    printf "        , %s AS %s\n" "${exprs_ref[i]}" "$(mysql_ident "${names_ref[i]}")" >> "$file"
  done
}

write_mysql_location_batch_procedures() {
  local file="$1"
  local definer="$2"
  local routine_names=() routine_exprs=() routine_types=()
  local location_entity_table
  routine_select_parts routine_names routine_exprs routine_types
  if is_city_location; then
    location_entity_table="city"
  else
    location_entity_table="country"
  fi
  cat >> "$file" <<SQL
DROP PROCEDURE IF EXISTS $(mysql_ident find_effective_geoname_ids_by_ips_json)\$\$
DROP PROCEDURE IF EXISTS $(mysql_ident find_e_geoname_ids_by_json_ips)\$\$
CREATE ${definer}PROCEDURE $(mysql_ident find_e_geoname_ids_by_json_ips)(ips_json JSON, page_param BIGINT UNSIGNED, per_page_param BIGINT UNSIGNED)
    READS SQL DATA
BEGIN
    IF ips_json IS NULL OR JSON_TYPE(ips_json) <> 'ARRAY' THEN
        SIGNAL SQLSTATE '22032' SET MESSAGE_TEXT = 'ips_json must be a JSON array';
    END IF;
    IF page_param IS NULL OR page_param < 1 THEN
        SIGNAL SQLSTATE '22023' SET MESSAGE_TEXT = 'page must be greater than or equal to 1';
    END IF;
    IF per_page_param IS NULL OR per_page_param < 1 THEN
        SIGNAL SQLSTATE '22023' SET MESSAGE_TEXT = 'per_page must be greater than or equal to 1';
    END IF;
    WITH input AS (
        SELECT CAST(j.$(ident ord) AS UNSIGNED) AS $(ident ord),
               JSON_LENGTH(ips_json) AS $(ident total_count),
               j.$(ident ip) AS $(ident ip),
               $(mysql_ident find_e_geoname_id_by_ip)(j.$(ident ip)) AS $(ident e_geoname_id)
        FROM JSON_TABLE(ips_json, '\$[*]' COLUMNS (
            $(ident ord) FOR ORDINALITY,
            $(ident ip) VARCHAR(45) PATH '\$'
        )) AS j
        WHERE j.$(ident ord) > (page_param - 1) * per_page_param
          AND j.$(ident ord) <= page_param * per_page_param
    )
    SELECT i.$(ident ord) AS $(ident ord), i.$(ident total_count) AS $(ident total_count),
           i.$(ident ip) AS $(ident ip), i.$(ident e_geoname_id) AS $(ident e_geoname_id)
    FROM input i
    ORDER BY i.$(ident ord);
END\$\$

DROP PROCEDURE IF EXISTS $(mysql_ident find_geoinfo_by_geoname_ids_json)\$\$
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoinfo_by_json_geoname_ids)\$\$
CREATE ${definer}PROCEDURE $(mysql_ident find_geoinfo_by_json_geoname_ids)(
    geoname_ids_json JSON,
    include_continent INT UNSIGNED,
    include_iso_code INT UNSIGNED,
    include_emoji INT UNSIGNED,
    page_param BIGINT UNSIGNED,
    per_page_param BIGINT UNSIGNED
)
    READS SQL DATA
BEGIN
    IF geoname_ids_json IS NULL OR JSON_TYPE(geoname_ids_json) <> 'ARRAY' THEN
        SIGNAL SQLSTATE '22032' SET MESSAGE_TEXT = 'geoname_ids_json must be a JSON array';
    END IF;
    IF page_param IS NULL OR page_param < 1 THEN
        SIGNAL SQLSTATE '22023' SET MESSAGE_TEXT = 'page must be greater than or equal to 1';
    END IF;
    IF per_page_param IS NULL OR per_page_param < 1 THEN
        SIGNAL SQLSTATE '22023' SET MESSAGE_TEXT = 'per_page must be greater than or equal to 1';
    END IF;
    WITH input AS (
        SELECT CAST(j.$(ident ord) AS UNSIGNED) AS $(ident ord),
               JSON_LENGTH(geoname_ids_json) AS $(ident total_count),
               CAST(j.$(ident geoname_id) AS UNSIGNED) AS $(ident geoname_id)
        FROM JSON_TABLE(geoname_ids_json, '\$[*]' COLUMNS (
            $(ident ord) FOR ORDINALITY,
            $(ident geoname_id) INT PATH '\$'
        )) AS j
        WHERE j.$(ident ord) > (page_param - 1) * per_page_param
          AND j.$(ident ord) <= page_param * per_page_param
    )
SQL
  write_mysql_batch_geoinfo_select_columns "$file" false routine_names routine_exprs
  write_geoname_lookup_from_input_sql "$file" "    " "i.$(ident geoname_id)"
  cat >> "$file" <<SQL
    ORDER BY i.$(ident ord);
END\$\$

DROP PROCEDURE IF EXISTS $(mysql_ident find_geoinfo_by_ips_json)\$\$
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoinfo_by_json_ips)\$\$
CREATE ${definer}PROCEDURE $(mysql_ident find_geoinfo_by_json_ips)(
    ips_json JSON,
    include_continent INT UNSIGNED,
    include_iso_code INT UNSIGNED,
    include_emoji INT UNSIGNED,
    page_param BIGINT UNSIGNED,
    per_page_param BIGINT UNSIGNED
)
    READS SQL DATA
BEGIN
    IF ips_json IS NULL OR JSON_TYPE(ips_json) <> 'ARRAY' THEN
        SIGNAL SQLSTATE '22032' SET MESSAGE_TEXT = 'ips_json must be a JSON array';
    END IF;
    IF page_param IS NULL OR page_param < 1 THEN
        SIGNAL SQLSTATE '22023' SET MESSAGE_TEXT = 'page must be greater than or equal to 1';
    END IF;
    IF per_page_param IS NULL OR per_page_param < 1 THEN
        SIGNAL SQLSTATE '22023' SET MESSAGE_TEXT = 'per_page must be greater than or equal to 1';
    END IF;
    WITH input AS (
        SELECT CAST(j.$(ident ord) AS UNSIGNED) AS $(ident ord),
               JSON_LENGTH(ips_json) AS $(ident total_count),
               j.$(ident ip) AS $(ident ip),
               $(mysql_ident find_e_geoname_id_by_ip)(j.$(ident ip)) AS $(ident geoname_id)
        FROM JSON_TABLE(ips_json, '\$[*]' COLUMNS (
            $(ident ord) FOR ORDINALITY,
            $(ident ip) VARCHAR(45) PATH '\$'
        )) AS j
        WHERE j.$(ident ord) > (page_param - 1) * per_page_param
          AND j.$(ident ord) <= page_param * per_page_param
    )
SQL
  write_mysql_batch_geoinfo_select_columns "$file" true routine_names routine_exprs
  write_geoname_lookup_from_input_sql "$file" "    " "i.$(ident geoname_id)"
  cat >> "$file" <<SQL
    ORDER BY i.$(ident ord);
END\$\$

SQL
  if [[ -n "$(location_label_expr locale_param include_continent include_iso_code include_emoji)" ]]; then
    cat >> "$file" <<SQL
DROP PROCEDURE IF EXISTS $(mysql_ident build_location_labels_by_geoname_ids_json)\$\$
DROP PROCEDURE IF EXISTS $(mysql_ident build_location_labels_by_json_geoname_ids)\$\$
CREATE ${definer}PROCEDURE $(mysql_ident build_location_labels_by_json_geoname_ids)(
    geoname_ids_json JSON,
    locale_param VARCHAR(16),
    include_continent INT UNSIGNED,
    include_iso_code INT UNSIGNED,
    include_emoji INT UNSIGNED,
    page_param BIGINT UNSIGNED,
    per_page_param BIGINT UNSIGNED
)
    READS SQL DATA
    SQL SECURITY INVOKER
BEGIN
    IF geoname_ids_json IS NULL OR JSON_TYPE(geoname_ids_json) <> 'ARRAY' THEN
        SIGNAL SQLSTATE '22032' SET MESSAGE_TEXT = 'geoname_ids_json must be a JSON array';
    END IF;
    IF page_param IS NULL OR page_param < 1 THEN
        SIGNAL SQLSTATE '22023' SET MESSAGE_TEXT = 'page must be greater than or equal to 1';
    END IF;
    IF per_page_param IS NULL OR per_page_param < 1 THEN
        SIGNAL SQLSTATE '22023' SET MESSAGE_TEXT = 'per_page must be greater than or equal to 1';
    END IF;
    WITH raw_input AS (
        SELECT CAST(j.$(ident ord) AS UNSIGNED) AS $(ident ord),
               JSON_LENGTH(geoname_ids_json) AS $(ident total_count),
               JSON_EXTRACT(geoname_ids_json, CONCAT('\$[', j.$(ident ord) - 1, ']')) AS $(ident value)
        FROM JSON_TABLE(geoname_ids_json, '\$[*]' COLUMNS (
            $(ident ord) FOR ORDINALITY
        )) AS j
        WHERE j.$(ident ord) > (page_param - 1) * per_page_param
          AND j.$(ident ord) <= page_param * per_page_param
    ), input AS (
        SELECT r.$(ident ord), r.$(ident total_count),
               CASE
                 WHEN JSON_TYPE(r.$(ident value)) IN ('INTEGER', 'STRING')
                  AND JSON_UNQUOTE(r.$(ident value)) REGEXP '^[0-9]+\$'
                 THEN CASE
                        WHEN CAST(JSON_UNQUOTE(r.$(ident value)) AS DECIMAL(20,0)) BETWEEN 1 AND 2147483647
                        THEN CAST(JSON_UNQUOTE(r.$(ident value)) AS UNSIGNED)
                      END
               END AS $(ident geoname_id)
        FROM raw_input r
    ), resolved AS (
        SELECT i.$(ident ord), i.$(ident total_count), i.$(ident geoname_id),
               CASE
                 WHEN i.$(ident geoname_id) IS NULL THEN 'invalid_geoname_id'
                 WHEN EXISTS (
                     SELECT 1
                     FROM $(mysql_ident "$location_entity_table") entity
                     WHERE entity.$(mysql_ident geoname_id) = i.$(mysql_ident geoname_id)
                 ) THEN 'ok'
                 ELSE 'not_found'
               END AS $(ident status),
               $(mysql_ident build_location_label_by_geoname_id)(i.$(mysql_ident geoname_id), locale_param, include_continent, include_iso_code, include_emoji) AS $(ident location_label)
        FROM input i
    )
    SELECT r.$(ident ord), r.$(ident total_count), r.$(ident geoname_id), r.$(ident status), r.$(ident location_label)
    FROM resolved r
    ORDER BY r.$(ident ord);
END\$\$

SQL
  else
    cat >> "$file" <<SQL
DROP PROCEDURE IF EXISTS $(mysql_ident build_location_labels_by_geoname_ids_json)\$\$
DROP PROCEDURE IF EXISTS $(mysql_ident build_location_labels_by_json_geoname_ids)\$\$
-- build_location_labels_by_json_geoname_ids was not generated because no configured location label columns can be returned.

SQL
  fi
}

write_pg_batch_geoinfo_select_columns() {
  local file="$1"
  local include_ip="$2"
  local -n names_ref="$3"
  local -n exprs_ref="$4"
  local i
  echo "SELECT" >> "$file"
  echo "    i.$(pg_ident ord)" >> "$file"
  echo "    , i.$(pg_ident total_count)" >> "$file"
  if [[ "$include_ip" == "true" ]]; then
    echo "    , i.$(pg_ident ip)" >> "$file"
  fi
  echo "    , i.$(pg_ident geoname_id) AS $(pg_ident geoname_id)" >> "$file"
  for ((i = 0; i < ${#names_ref[@]}; i++)); do
    printf "    , %s AS %s\n" "${exprs_ref[i]}" "$(pg_ident "${names_ref[i]}")" >> "$file"
  done
}

write_pg_location_batch_functions() {
  local file="$1"
  local routine_names=() routine_exprs=() routine_types=()
  local return_cols i location_entity_table
  routine_select_parts routine_names routine_exprs routine_types
  if is_city_location; then
    location_entity_table="city"
  else
    location_entity_table="country"
  fi
  return_cols="$(pg_ident ord) integer, $(pg_ident total_count) bigint, $(pg_ident ip) text, $(pg_ident e_geoname_id) integer"
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident find_effective_geoname_ids_by_ips_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_effective_geoname_ids_by_ips_json)(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_e_geoname_ids_by_json_ips)(jsonb, integer, integer);

CREATE OR REPLACE FUNCTION $(pg_ident find_e_geoname_ids_by_json_ips)(p_ips jsonb, p_page integer, p_per_page integer)
RETURNS TABLE($return_cols)
LANGUAGE sql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
SELECT item.$(ident ord)::integer AS $(ident ord),
       jsonb_array_length(p_ips)::bigint AS $(ident total_count),
       item.$(ident ip) AS $(ident ip),
       $(pg_ident find_e_geoname_id_by_ip)(item.$(ident ip)) AS $(ident e_geoname_id)
FROM jsonb_array_elements_text(p_ips) WITH ORDINALITY AS item($(ident ip), $(ident ord))
ORDER BY item.$(ident ord)
LIMIT p_per_page OFFSET $(pg_ident _batch_page_offset)(p_page, p_per_page);
\$\$;

SQL
  return_cols="$(pg_ident ord) integer, $(pg_ident total_count) bigint, $(pg_ident geoname_id) integer"
  for ((i = 0; i < ${#routine_names[@]}; i++)); do
    return_cols="${return_cols}, $(pg_ident "${routine_names[i]}") ${routine_types[i]}"
  done
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_geoname_ids_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_geoname_ids_json)(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_json_geoname_ids)(jsonb, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_json_geoname_ids)(jsonb, integer, integer, integer, integer, integer);

CREATE OR REPLACE FUNCTION $(pg_ident find_geoinfo_by_json_geoname_ids)(
    p_geoname_ids jsonb,
    include_continent integer,
    include_iso_code integer,
    include_emoji integer,
    p_page integer,
    p_per_page integer
)
RETURNS TABLE($return_cols)
LANGUAGE sql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
WITH input AS (
    SELECT item.$(ident ord)::integer AS $(ident ord),
           jsonb_array_length(p_geoname_ids)::bigint AS $(ident total_count),
           item.$(ident geoname_id)::integer AS $(ident geoname_id)
    FROM jsonb_array_elements_text(p_geoname_ids) WITH ORDINALITY AS item($(ident geoname_id), $(ident ord))
    ORDER BY item.$(ident ord)
    LIMIT p_per_page OFFSET $(pg_ident _batch_page_offset)(p_page, p_per_page)
)
SQL
  write_pg_batch_geoinfo_select_columns "$file" false routine_names routine_exprs
  write_geoname_lookup_from_input_sql "$file" "" "i.$(ident geoname_id)"
  cat >> "$file" <<SQL
ORDER BY i.$(ident ord);
\$\$;

SQL
  return_cols="$(pg_ident ord) integer, $(pg_ident total_count) bigint, $(pg_ident ip) text, $(pg_ident geoname_id) integer"
  for ((i = 0; i < ${#routine_names[@]}; i++)); do
    return_cols="${return_cols}, $(pg_ident "${routine_names[i]}") ${routine_types[i]}"
  done
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_ips_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_ips_json)(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_json_ips)(jsonb, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_json_ips)(jsonb, integer, integer, integer, integer, integer);

CREATE OR REPLACE FUNCTION $(pg_ident find_geoinfo_by_json_ips)(
    p_ips jsonb,
    include_continent integer,
    include_iso_code integer,
    include_emoji integer,
    p_page integer,
    p_per_page integer
)
RETURNS TABLE($return_cols)
LANGUAGE sql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
WITH input AS (
    SELECT item.$(ident ord)::integer AS $(ident ord),
           jsonb_array_length(p_ips)::bigint AS $(ident total_count),
           item.$(ident ip) AS $(ident ip),
           $(pg_ident find_e_geoname_id_by_ip)(item.$(ident ip)) AS $(ident geoname_id)
    FROM jsonb_array_elements_text(p_ips) WITH ORDINALITY AS item($(ident ip), $(ident ord))
    ORDER BY item.$(ident ord)
    LIMIT p_per_page OFFSET $(pg_ident _batch_page_offset)(p_page, p_per_page)
)
SQL
  write_pg_batch_geoinfo_select_columns "$file" true routine_names routine_exprs
  write_geoname_lookup_from_input_sql "$file" "" "i.$(ident geoname_id)"
  cat >> "$file" <<SQL
ORDER BY i.$(ident ord);
\$\$;

SQL
  if [[ -n "$(location_label_expr locale_param include_continent include_iso_code include_emoji)" ]]; then
    cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident build_location_labels_by_geoname_ids_json)(jsonb, text, integer, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident build_location_labels_by_geoname_ids_json)(jsonb, text, integer, integer, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident build_location_labels_by_json_geoname_ids)(jsonb, text, integer, integer, integer, integer, integer);

CREATE OR REPLACE FUNCTION $(pg_ident build_location_labels_by_json_geoname_ids)(
    p_geoname_ids jsonb,
    locale_param text,
    include_continent integer,
    include_iso_code integer,
    include_emoji integer,
    p_page integer,
    p_per_page integer
)
RETURNS TABLE($(pg_ident ord) integer, $(pg_ident total_count) bigint, $(pg_ident geoname_id) integer, $(pg_ident status) text, $(pg_ident location_label) text)
LANGUAGE sql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
WITH raw_input AS (
    SELECT item.$(ident ord)::integer AS $(ident ord),
           jsonb_array_length(p_geoname_ids)::bigint AS $(ident total_count),
           CASE
             WHEN jsonb_typeof(item.$(ident value)) IN ('number', 'string')
             THEN item.$(ident value) #>> '{}'
           END AS $(ident value)
    FROM jsonb_array_elements(COALESCE(p_geoname_ids, 'null'::jsonb)) WITH ORDINALITY AS item($(ident value), $(ident ord))
    ORDER BY item.$(ident ord)
    LIMIT p_per_page OFFSET $(pg_ident _batch_page_offset)(p_page, p_per_page)
), input AS (
    SELECT r.$(ident ord), r.$(ident total_count),
           CASE
             WHEN r.$(ident value) ~ '^[0-9]+\$'
              AND pg_input_is_valid(r.$(ident value), 'integer')
             THEN CASE
                    WHEN r.$(ident value)::integer > 0 THEN r.$(ident value)::integer
                  END
           END AS $(ident geoname_id)
    FROM raw_input r
)
SELECT i.$(ident ord),
       i.$(ident total_count),
       i.$(ident geoname_id),
       CASE
         WHEN i.$(ident geoname_id) IS NULL THEN 'invalid_geoname_id'
         WHEN EXISTS (
             SELECT 1
             FROM $(pg_ident "$location_entity_table") entity
             WHERE entity.$(pg_ident geoname_id) = i.$(pg_ident geoname_id)
         ) THEN 'ok'
         ELSE 'not_found'
       END AS $(ident status),
       $(pg_ident build_location_label_by_geoname_id)(i.$(pg_ident geoname_id), locale_param, include_continent, include_iso_code, include_emoji) AS $(ident location_label)
FROM input i
ORDER BY i.$(ident ord);
\$\$;

SQL
  else
    cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident build_location_labels_by_geoname_ids_json)(jsonb, text, integer, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident build_location_labels_by_geoname_ids_json)(jsonb, text, integer, integer, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident build_location_labels_by_json_geoname_ids)(jsonb, text, integer, integer, integer, integer, integer);
-- build_location_labels_by_json_geoname_ids was not generated because no configured location label columns can be returned.

SQL
  fi
}

write_mysql_location_labels_network_lookup() {
  local file="$1"
  local table="$2"
  local value_var="$3"
  shift 3
  local roles=("$@")
  local role candidate_role_selects="" inner_role_selects="" into_role_vars=""
  for role in "${roles[@]}"; do
    candidate_role_selects+=$',\n'"               candidate.$(ident "$role") AS $(ident "$role")"
    into_role_vars+=$',\n'"             v_$role"
    if column_enabled "$table" "$role"; then
      inner_role_selects+=$',\n'"                   b.$(ident "$role") AS $(ident "$role")"
    else
      inner_role_selects+=$',\n'"                   NULL AS $(ident "$role")"
    fi
  done
  cat >> "$file" <<SQL
        SELECT candidate.$(ident network), candidate.$(ident e_geoname_id), candidate.$(ident e_geoname_source_code)$candidate_role_selects
        INTO v_network, v_e_geoname_id, v_e_geoname_source_code$into_role_vars
        FROM (SELECT 1 AS $(ident seed)) seed
        LEFT JOIN (
            SELECT b.$(ident network), b.$(ident e_geoname_id), b.$(ident e_geoname_source_code)$inner_role_selects,
                   b.$(ident last_ip) AS $(ident __last_ip)
            FROM $(ident "$table") b
            WHERE b.$(ident start_ip) <= $value_var
            ORDER BY b.$(ident start_ip) DESC
            LIMIT 1
        ) candidate ON candidate.$(ident __last_ip) >= $value_var;
SQL
}

write_mysql_location_labels_by_ip_procedure() {
  local file="$1"
  local definer="$2"
  local has4="$3"
  local has6="$4"
  local role label_column output_role_selects=""
  local roles=()
  mapfile -t roles < <(enabled_geoname_role_columns)
  for role in "${roles[@]}"; do
    label_column="$(geoname_role_label_column "$role")"
    output_role_selects+=$',\n'"            v_$role AS $(ident "$role"),"
    output_role_selects+=$'\n'"            CASE WHEN l.$(ident locale) IS NOT NULL THEN $(mysql_ident build_location_label_by_geoname_id)(v_$role, l.$(ident locale), include_continent, include_iso_code, include_emoji) END AS $(ident "$label_column")"
  done
  cat >> "$file" <<SQL
DROP PROCEDURE IF EXISTS $(mysql_ident build_location_labels_by_ip)\$\$
CREATE ${definer}PROCEDURE $(mysql_ident build_location_labels_by_ip)(
    ip_param VARCHAR(45),
    locales_json JSON,
    include_continent INT UNSIGNED,
    include_iso_code INT UNSIGNED,
    include_emoji INT UNSIGNED
)
    READS SQL DATA
    SQL SECURITY INVOKER
BEGIN
    DECLARE v_status VARCHAR(16) DEFAULT 'invalid_ip';
    DECLARE v_ip_version TINYINT UNSIGNED DEFAULT NULL;
    DECLARE v_network VARCHAR(43) DEFAULT NULL;
    DECLARE v_e_geoname_id INT UNSIGNED DEFAULT NULL;
    DECLARE v_e_geoname_source_code TINYINT UNSIGNED DEFAULT NULL;
SQL
  for role in "${roles[@]}"; do
    echo "    DECLARE v_$role INT UNSIGNED DEFAULT NULL;" >> "$file"
  done
  [[ "$has4" == "true" ]] && echo "    DECLARE v_ip4 INT UNSIGNED DEFAULT NULL;" >> "$file"
  [[ "$has6" == "true" ]] && echo "    DECLARE v_ip6 DECIMAL(39,0) DEFAULT NULL;" >> "$file"
  cat >> "$file" <<SQL

    IF locales_json IS NULL OR JSON_TYPE(locales_json) <> 'ARRAY' THEN
        SIGNAL SQLSTATE '22032' SET MESSAGE_TEXT = 'locales_json must be a JSON array';
    END IF;
    IF include_continent IS NULL OR include_continent NOT IN (0, 1)
       OR include_iso_code IS NULL OR include_iso_code NOT IN (0, 1)
       OR include_emoji IS NULL OR include_emoji NOT IN (0, 1) THEN
        SIGNAL SQLSTATE '22023' SET MESSAGE_TEXT = 'include flags must be 0 or 1';
    END IF;

    IF IS_IPV6(ip_param) = 1 THEN
        SET v_ip_version = 6;
        SET v_status = 'not_found';
SQL
  if [[ "$has6" == "true" ]]; then
    cat >> "$file" <<SQL
        SET v_ip6 = $(mysql_ident inet6_aton_decimal)(ip_param);
SQL
    write_mysql_location_labels_network_lookup "$file" ipv6 v_ip6 "${roles[@]}"
  fi
  cat >> "$file" <<SQL
    ELSEIF IS_IPV4(ip_param) = 1 THEN
        SET v_ip_version = 4;
        SET v_status = 'not_found';
SQL
  if [[ "$has4" == "true" ]]; then
    cat >> "$file" <<SQL
        SET v_ip4 = INET_ATON(ip_param);
SQL
    write_mysql_location_labels_network_lookup "$file" ipv4 v_ip4 "${roles[@]}"
  fi
  cat >> "$file" <<SQL
    END IF;

    IF v_network IS NOT NULL THEN
        SET v_status = CASE WHEN v_e_geoname_id IS NULL THEN 'no_location' ELSE 'ok' END;
    END IF;

    WITH raw_locales AS (
        SELECT CAST(j.$(ident ord) AS UNSIGNED) AS $(ident ord),
               JSON_EXTRACT(locales_json, CONCAT('\$[', j.$(ident ord) - 1, ']')) AS $(ident value)
        FROM JSON_TABLE(locales_json, '\$[*]' COLUMNS ($(ident ord) FOR ORDINALITY)) AS j
    ), locales AS (
        SELECT r.$(ident ord),
               CASE WHEN JSON_TYPE(r.$(ident value)) = 'STRING'
                    THEN NULLIF(LOWER(REPLACE(TRIM(BOTH '"' FROM TRIM(JSON_UNQUOTE(r.$(ident value)))), '_', '-')), '')
               END AS $(ident locale)
        FROM raw_locales r
    )
    SELECT l.$(ident ord), l.$(ident locale),
           CASE WHEN l.$(ident locale) IS NULL THEN 'invalid_locale' ELSE v_status END AS $(ident status),
           ip_param AS $(ident ip), v_ip_version AS $(ident ip_version), v_network AS $(ident network),
           v_e_geoname_id AS $(ident e_geoname_id),
           CASE v_e_geoname_source_code
             WHEN 1 THEN 'geoname_id'
             WHEN 2 THEN 'registered_country_geoname_id'
             WHEN 3 THEN 'represented_country_geoname_id'
           END AS $(ident e_geoname_source),
           CASE WHEN l.$(ident locale) IS NOT NULL THEN $(mysql_ident build_location_label_by_geoname_id)(v_e_geoname_id, l.$(ident locale), include_continent, include_iso_code, include_emoji) END AS $(ident e_geoname_label)$output_role_selects
    FROM locales l
    ORDER BY l.$(ident ord);
END\$\$

SQL
}

write_pg_location_labels_by_ip_function() {
  local file="$1"
  local role label_column return_role_columns="" select_role_columns=""
  local roles=()
  mapfile -t roles < <(enabled_geoname_role_columns)
  for role in "${roles[@]}"; do
    label_column="$(geoname_role_label_column "$role")"
    return_role_columns+=$',\n'"    $(pg_ident "$role") integer,"
    return_role_columns+=$'\n'"    $(pg_ident "$label_column") text"
    select_role_columns+=$',\n'"           n.$(ident "$role") AS $(ident "$role"),"
    select_role_columns+=$'\n'"           CASE WHEN l.$(ident locale) IS NOT NULL THEN $(pg_ident build_location_label_by_geoname_id)(n.$(ident "$role"), l.$(ident locale), include_continent, include_iso_code, include_emoji) END AS $(ident "$label_column")"
  done
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident build_location_labels_by_ip)(text, jsonb, integer, integer, integer);

CREATE OR REPLACE FUNCTION $(pg_ident build_location_labels_by_ip)(
    p_ip text,
    p_locales jsonb,
    include_continent integer,
    include_iso_code integer,
    include_emoji integer
)
RETURNS TABLE(
    $(pg_ident ord) integer,
    $(pg_ident locale) text,
    $(pg_ident status) text,
    $(pg_ident ip) text,
    $(pg_ident ip_version) integer,
    $(pg_ident network) cidr,
    $(pg_ident e_geoname_id) integer,
    $(pg_ident e_geoname_source) text,
    $(pg_ident e_geoname_label) text$return_role_columns
)
LANGUAGE plpgsql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
BEGIN
    IF p_locales IS NULL OR jsonb_typeof(p_locales) <> 'array' THEN
        RAISE EXCEPTION 'locales_json must be a JSON array' USING ERRCODE = '22032';
    END IF;
    IF include_continent IS NULL OR include_continent NOT IN (0, 1)
       OR include_iso_code IS NULL OR include_iso_code NOT IN (0, 1)
       OR include_emoji IS NULL OR include_emoji NOT IN (0, 1) THEN
        RAISE EXCEPTION 'include flags must be 0 or 1' USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    WITH network_row AS MATERIALIZED (
        SELECT n.* FROM $(pg_ident find_geoname_ids_by_ip)(p_ip) n
    ), raw_locales AS (
        SELECT item.$(ident ord)::integer AS $(ident ord),
               CASE WHEN jsonb_typeof(item.$(ident value)) = 'string'
                    THEN NULLIF(lower(replace(btrim(btrim(item.$(ident value) #>> '{}'), '"'), '_', '-')), '')
               END AS $(ident locale)
        FROM jsonb_array_elements(p_locales) WITH ORDINALITY AS item($(ident value), $(ident ord))
    )
    SELECT l.$(ident ord), l.$(ident locale),
           CASE WHEN l.$(ident locale) IS NULL THEN 'invalid_locale' ELSE n.$(ident status) END AS $(ident status),
           n.$(ident ip), n.$(ident ip_version), n.$(ident network),
           n.$(ident e_geoname_id), n.$(ident e_geoname_source),
           CASE WHEN l.$(ident locale) IS NOT NULL THEN $(pg_ident build_location_label_by_geoname_id)(n.$(ident e_geoname_id), l.$(ident locale), include_continent, include_iso_code, include_emoji) END AS $(ident e_geoname_label)$select_role_columns
    FROM raw_locales l
    CROSS JOIN network_row n
    ORDER BY l.$(ident ord);
END;
\$\$;

SQL
}

write_mysql_dataset_metadata_procedure() {
  local file="$1"
  local definer="$2"
  cat >> "$file" <<SQL
DELIMITER \$\$
DROP PROCEDURE IF EXISTS $(mysql_ident get_dataset_metadata)\$\$
CREATE ${definer}PROCEDURE $(mysql_ident get_dataset_metadata)()
    READS SQL DATA
    SQL SECURITY INVOKER
BEGIN
    SELECT $(mysql_ident run_id), $(mysql_ident edition_id), $(mysql_ident archive_root), $(mysql_ident source_build_date),
           $(mysql_ident imported_at), $(mysql_ident converter_version), $(mysql_ident schema_version), $(mysql_ident dbms),
           $(mysql_ident project_name), $(mysql_ident schema_name), $(mysql_ident ip_versions), $(mysql_ident selected_locales),
           $(mysql_ident loaded_locales), $(mysql_ident e_geoname_id_priority_columns)
    FROM $(mysql_ident dataset_metadata);
END\$\$
DELIMITER ;

SQL
}

write_pg_dataset_metadata_function() {
  local file="$1"
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident get_dataset_metadata)();

CREATE OR REPLACE FUNCTION $(pg_ident get_dataset_metadata)()
RETURNS TABLE(
    $(pg_ident run_id) varchar(64),
    $(pg_ident edition_id) varchar(64),
    $(pg_ident archive_root) varchar(255),
    $(pg_ident source_build_date) date,
    $(pg_ident imported_at) timestamptz,
    $(pg_ident converter_version) varchar(32),
    $(pg_ident schema_version) integer,
    $(pg_ident dbms) varchar(16),
    $(pg_ident project_name) varchar(128),
    $(pg_ident schema_name) varchar(128),
    $(pg_ident ip_versions) jsonb,
    $(pg_ident selected_locales) jsonb,
    $(pg_ident loaded_locales) jsonb,
    $(pg_ident e_geoname_id_priority_columns) jsonb
)
LANGUAGE sql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
SELECT m.$(pg_ident run_id), m.$(pg_ident edition_id), m.$(pg_ident archive_root), m.$(pg_ident source_build_date),
       m.$(pg_ident imported_at), m.$(pg_ident converter_version), m.$(pg_ident schema_version), m.$(pg_ident dbms),
       m.$(pg_ident project_name), m.$(pg_ident schema_name), m.$(pg_ident ip_versions), m.$(pg_ident selected_locales),
       m.$(pg_ident loaded_locales), m.$(pg_ident e_geoname_id_priority_columns)
FROM $(pg_ident dataset_metadata) m;
\$\$;

SQL
}

write_mysql_original_geoname_id_function() {
  local file="$1"
  local definer="$2"
  local has4="$3"
  local has6="$4"
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(mysql_ident find_geoname_id_by_ip)\$\$
CREATE ${definer}FUNCTION $(mysql_ident find_geoname_id_by_ip)(ip VARCHAR(45)) RETURNS INT UNSIGNED
    READS SQL DATA
    DETERMINISTIC
    SQL SECURITY INVOKER
BEGIN
    DECLARE result INT UNSIGNED DEFAULT NULL;
SQL
  [[ "$has6" == "true" ]] && echo "    DECLARE ip6 DECIMAL(39,0) DEFAULT NULL;" >> "$file"
  [[ "$has4" == "true" ]] && echo "    DECLARE ip4 INT UNSIGNED DEFAULT NULL;" >> "$file"
  if [[ "$has6" == "true" ]]; then
    cat >> "$file" <<SQL
    IF IS_IPV6(ip) = 1 THEN
        SET ip6 = $(mysql_ident inet6_aton_decimal)(ip);
        SELECT candidate.$(mysql_ident geoname_id) INTO result
        FROM (SELECT $(mysql_ident geoname_id), $(mysql_ident last_ip) FROM $(mysql_ident ipv6) WHERE $(mysql_ident start_ip) <= ip6 ORDER BY $(mysql_ident start_ip) DESC LIMIT 1) AS candidate
        WHERE candidate.$(mysql_ident last_ip) >= ip6;
        RETURN result;
    END IF;
SQL
  fi
  if [[ "$has4" == "true" ]]; then
    cat >> "$file" <<SQL
    IF IS_IPV4(ip) = 0 THEN RETURN NULL; END IF;
    SET ip4 = INET_ATON(ip);
    SELECT candidate.$(mysql_ident geoname_id) INTO result
    FROM (SELECT $(mysql_ident geoname_id), $(mysql_ident last_ip) FROM $(mysql_ident ipv4) WHERE $(mysql_ident start_ip) <= ip4 ORDER BY $(mysql_ident start_ip) DESC LIMIT 1) AS candidate
    WHERE candidate.$(mysql_ident last_ip) >= ip4;
    RETURN result;
SQL
  else
    echo "    RETURN NULL;" >> "$file"
  fi
  cat >> "$file" <<SQL
END\$\$

SQL
}

write_pg_original_geoname_id_function() {
  local file="$1"
  local has4="$2"
  local has6="$3"
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident find_geoname_id_by_ip)(text);

CREATE OR REPLACE FUNCTION $(pg_ident find_geoname_id_by_ip)(p_ip text)
RETURNS integer
LANGUAGE plpgsql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
DECLARE
    v_ip inet;
    result integer;
BEGIN
    IF p_ip IS NULL OR position('/' in p_ip) > 0 OR NOT pg_input_is_valid(p_ip, 'inet') THEN
        RETURN NULL;
    END IF;
    v_ip := p_ip::inet;
SQL
  if [[ "$has4" == "true" ]]; then
    cat >> "$file" <<SQL
    IF family(v_ip) = 4 THEN
        SELECT candidate.$(pg_ident geoname_id) INTO result
        FROM (SELECT $(pg_ident geoname_id), $(pg_ident last_ip) FROM $(pg_ident ipv4) WHERE $(pg_ident start_ip) <= v_ip ORDER BY $(pg_ident start_ip) DESC LIMIT 1) AS candidate
        WHERE candidate.$(pg_ident last_ip) >= v_ip;
        RETURN result;
    END IF;
SQL
  fi
  if [[ "$has6" == "true" ]]; then
    cat >> "$file" <<SQL
    IF family(v_ip) = 6 THEN
        SELECT candidate.$(pg_ident geoname_id) INTO result
        FROM (SELECT $(pg_ident geoname_id), $(pg_ident last_ip) FROM $(pg_ident ipv6) WHERE $(pg_ident start_ip) <= v_ip ORDER BY $(pg_ident start_ip) DESC LIMIT 1) AS candidate
        WHERE candidate.$(pg_ident last_ip) >= v_ip;
        RETURN result;
    END IF;
SQL
  fi
  cat >> "$file" <<SQL
    RETURN NULL;
END;
\$\$;

SQL
}

write_99_routines() {
  local file="$RUN_DIR/99_routines.sql"
  local definer="" has4=false has6=false has_geoname4=false has_geoname6=false locale return_cols routine_names routine_exprs routine_types i
  array_contains "4" "${IP_VERSIONS[@]}" && has4=true
  array_contains "6" "${IP_VERSIONS[@]}" && has6=true
  [[ "$has4" == "true" ]] && column_enabled ipv4 geoname_id && has_geoname4=true
  [[ "$has6" == "true" ]] && column_enabled ipv6 geoname_id && has_geoname6=true
  start_sql_file "$file" "IP lookup helper functions and procedures"
  if ! is_location_family; then
    if [[ "$DBMS" == "mysql" ]]; then
      [[ -n "$MYSQL_ROUTINE_DEFINER" ]] && definer="DEFINER=$MYSQL_ROUTINE_DEFINER "
      write_mysql_inet6_function "$file"
      write_mysql_dataset_metadata_procedure "$file" "$definer"
      cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(mysql_ident find_effective_geoname_id_by_ip);
DROP FUNCTION IF EXISTS $(mysql_ident find_e_geoname_id_by_ip);
DROP FUNCTION IF EXISTS $(mysql_ident find_geoname_id_by_ip);
DROP PROCEDURE IF EXISTS $(mysql_ident find_ip_geoname_ids_by_ip);
DROP PROCEDURE IF EXISTS $(mysql_ident find_ip_geoname_ids_by_ips_json);
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoname_ids_by_ip);
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoname_ids_by_json_ips);
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoinfo_by_ip);
DROP PROCEDURE IF EXISTS $(mysql_ident find_effective_geoname_ids_by_ips_json);
DROP PROCEDURE IF EXISTS $(mysql_ident find_e_geoname_ids_by_json_ips);
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoinfo_by_ips_json);
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoinfo_by_geoname_ids_json);
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoinfo_by_json_ips);
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoinfo_by_json_geoname_ids);
DROP PROCEDURE IF EXISTS $(mysql_ident build_location_labels_by_geoname_ids_json);
DROP PROCEDURE IF EXISTS $(mysql_ident build_location_labels_by_ip);
DROP PROCEDURE IF EXISTS $(mysql_ident build_location_labels_by_json_geoname_ids);
DROP FUNCTION IF EXISTS $(mysql_ident build_location_label);
DROP FUNCTION IF EXISTS $(mysql_ident build_location_label_by_geoname_id);

SQL
      write_mysql_network_lookup_procedure "$file" "$definer" "$has4" "$has6"
      write_mysql_network_lookup_batch_procedure "$file" "$definer" "$has4" "$has6"
    else
      write_pg_dataset_metadata_function "$file"
      write_pg_routine_precleanup "$file"
      write_pg_batch_page_offset_function "$file"
      cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident find_effective_geoname_id_by_ip)(text);
DROP FUNCTION IF EXISTS $(pg_ident find_e_geoname_id_by_ip)(text);
DROP FUNCTION IF EXISTS $(pg_ident find_geoname_id_by_ip)(text);
DROP FUNCTION IF EXISTS $(pg_ident find_ip_geoname_ids_by_ip)(text);
DROP FUNCTION IF EXISTS $(pg_ident find_ip_geoname_ids_by_ips_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_ip_geoname_ids_by_ips_json)(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoname_ids_by_ip)(text);
DROP FUNCTION IF EXISTS $(pg_ident find_geoname_ids_by_json_ips)(jsonb, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_ip)(text);
DROP FUNCTION IF EXISTS $(pg_ident find_effective_geoname_ids_by_ips_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_effective_geoname_ids_by_ips_json)(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_e_geoname_ids_by_json_ips)(jsonb, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_ips_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_ips_json)(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_geoname_ids_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_geoname_ids_json)(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_json_ips)(jsonb, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_json_geoname_ids)(jsonb, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_json_ips)(jsonb, integer, integer, integer, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_json_geoname_ids)(jsonb, integer, integer, integer, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident build_location_labels_by_geoname_ids_json)(jsonb, text, integer, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident build_location_labels_by_geoname_ids_json)(jsonb, text, integer, integer, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident build_location_labels_by_ip)(text, jsonb, integer, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident build_location_labels_by_json_geoname_ids)(jsonb, text, integer, integer, integer, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident build_location_label)(integer, text, integer, integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident build_location_label_by_geoname_id)(integer, text, integer, integer, integer);

SQL
      write_pg_network_lookup_function "$file" "$has4" "$has6"
      write_pg_network_lookup_family_functions "$file" "$has4" "$has6"
      write_pg_network_lookup_batch_function "$file" "$has4" "$has6"
      write_pg_network_lookup_batch_family_functions "$file" "$has4" "$has6"
    fi
    echo "-- Geoname/location lookup helpers were not generated for $ARCHIVE_EDITION_ID because this archive has no geoname_id/location tables." >> "$file"
    return 0
  fi
  if [[ "$DBMS" == "mysql" ]]; then
    [[ -n "$MYSQL_ROUTINE_DEFINER" ]] && definer="DEFINER=$MYSQL_ROUTINE_DEFINER "
    write_mysql_inet6_function "$file"
    write_mysql_dataset_metadata_procedure "$file" "$definer"
    write_mysql_network_lookup_procedure "$file" "$definer" "$has4" "$has6"
    write_mysql_network_lookup_batch_procedure "$file" "$definer" "$has4" "$has6"
    write_mysql_ip_geoname_lookup_procedure "$file" "$definer" "$has4" "$has6"
    write_mysql_ip_geoname_lookup_batch_procedure "$file" "$definer" "$has4" "$has6"
    cat >> "$file" <<SQL
DELIMITER \$\$
DROP FUNCTION IF EXISTS $(mysql_ident find_effective_geoname_id_by_ip)\$\$
DROP FUNCTION IF EXISTS $(mysql_ident find_e_geoname_id_by_ip)\$\$
CREATE ${definer}FUNCTION $(mysql_ident find_e_geoname_id_by_ip)(ip VARCHAR(45)) RETURNS INT UNSIGNED
    READS SQL DATA
    DETERMINISTIC
    SQL SECURITY INVOKER
BEGIN
    DECLARE result INT UNSIGNED DEFAULT NULL;
SQL
    [[ "$has6" == "true" ]] && echo "    DECLARE ip6 DECIMAL(39,0) DEFAULT NULL;" >> "$file"
    [[ "$has4" == "true" ]] && echo "    DECLARE ip4 INT UNSIGNED DEFAULT NULL;" >> "$file"
    if [[ "$has6" == "true" ]]; then
      cat >> "$file" <<SQL
    IF IS_IPV6(ip) = 1 THEN
        SET ip6 = $(mysql_ident inet6_aton_decimal)(ip);
        IF ip6 IS NULL THEN RETURN NULL; END IF;
        SELECT candidate.$(mysql_ident e_geoname_id) INTO result
        FROM (SELECT $(mysql_ident e_geoname_id), $(mysql_ident last_ip) FROM $(mysql_ident ipv6) WHERE $(mysql_ident start_ip) <= ip6 ORDER BY $(mysql_ident start_ip) DESC LIMIT 1) AS candidate
        WHERE candidate.$(mysql_ident last_ip) >= ip6;
        RETURN result;
    END IF;
SQL
    fi
    if [[ "$has4" == "true" ]]; then
      cat >> "$file" <<SQL
    IF IS_IPV4(ip) = 0 THEN RETURN NULL; END IF;
    SET ip4 = INET_ATON(ip);
    SELECT candidate.$(mysql_ident e_geoname_id) INTO result
    FROM (SELECT $(mysql_ident e_geoname_id), $(mysql_ident last_ip) FROM $(mysql_ident ipv4) WHERE $(mysql_ident start_ip) <= ip4 ORDER BY $(mysql_ident start_ip) DESC LIMIT 1) AS candidate
    WHERE candidate.$(mysql_ident last_ip) >= ip4;
    RETURN result;
SQL
    else
      echo "    RETURN NULL;" >> "$file"
    fi
    echo "END\$\$" >> "$file"
    echo >> "$file"
    if [[ "$has_geoname4" == "true" || "$has_geoname6" == "true" ]]; then
      write_mysql_original_geoname_id_function "$file" "$definer" "$has_geoname4" "$has_geoname6"
    else
      echo "DROP FUNCTION IF EXISTS $(mysql_ident find_geoname_id_by_ip)\$\$" >> "$file"
      echo "-- find_geoname_id_by_ip was not generated because geoname_id is disabled for every selected IP family." >> "$file"
      echo >> "$file"
    fi
    cat >> "$file" <<SQL
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoinfo_by_ip)\$\$

SQL
    write_mysql_build_location_functions "$file" "$definer"
    if [[ -n "$(location_label_expr locale_param include_continent include_iso_code include_emoji)" ]]; then
      write_mysql_location_labels_by_ip_procedure "$file" "$definer" "$has4" "$has6"
    else
      cat >> "$file" <<SQL
DROP PROCEDURE IF EXISTS $(mysql_ident build_location_labels_by_ip)\$\$
-- build_location_labels_by_ip was not generated because no configured location label columns can be returned.

SQL
    fi
    write_mysql_location_batch_procedures "$file" "$definer"
    echo "DELIMITER ;" >> "$file"
  else
    write_pg_dataset_metadata_function "$file"
    write_pg_routine_precleanup "$file"
    write_pg_batch_page_offset_function "$file"
    write_pg_network_lookup_function "$file" "$has4" "$has6"
    write_pg_network_lookup_family_functions "$file" "$has4" "$has6"
    write_pg_network_lookup_batch_function "$file" "$has4" "$has6"
    write_pg_network_lookup_batch_family_functions "$file" "$has4" "$has6"
    write_pg_ip_geoname_lookup_functions "$file"
    cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident find_effective_geoname_id_by_ip)(text);
DROP FUNCTION IF EXISTS $(pg_ident find_e_geoname_id_by_ip)(text);

CREATE OR REPLACE FUNCTION $(pg_ident find_e_geoname_id_by_ip)(p_ip text)
RETURNS integer
LANGUAGE plpgsql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
DECLARE
    v_ip inet;
    result integer;
BEGIN
    IF p_ip IS NULL OR position('/' in p_ip) > 0 OR NOT pg_input_is_valid(p_ip, 'inet') THEN
        RETURN NULL;
    END IF;
    v_ip := p_ip::inet;
SQL
    if [[ "$has4" == "true" ]]; then
      cat >> "$file" <<SQL
    IF family(v_ip) = 4 THEN
        SELECT candidate.$(pg_ident e_geoname_id) INTO result
        FROM (SELECT $(pg_ident e_geoname_id), $(pg_ident last_ip) FROM $(pg_ident ipv4) WHERE $(pg_ident start_ip) <= v_ip ORDER BY $(pg_ident start_ip) DESC LIMIT 1) AS candidate
        WHERE candidate.$(pg_ident last_ip) >= v_ip;
        RETURN result;
    END IF;
SQL
    fi
    if [[ "$has6" == "true" ]]; then
      cat >> "$file" <<SQL
    IF family(v_ip) = 6 THEN
        SELECT candidate.$(pg_ident e_geoname_id) INTO result
        FROM (SELECT $(pg_ident e_geoname_id), $(pg_ident last_ip) FROM $(pg_ident ipv6) WHERE $(pg_ident start_ip) <= v_ip ORDER BY $(pg_ident start_ip) DESC LIMIT 1) AS candidate
        WHERE candidate.$(pg_ident last_ip) >= v_ip;
        RETURN result;
    END IF;
SQL
    fi
    cat >> "$file" <<SQL
    RETURN NULL;
END;
\$\$;

SQL
    if [[ "$has_geoname4" == "true" || "$has_geoname6" == "true" ]]; then
      write_pg_original_geoname_id_function "$file" "$has_geoname4" "$has_geoname6"
    else
      echo "DROP FUNCTION IF EXISTS $(pg_ident find_geoname_id_by_ip)(text);" >> "$file"
      echo "-- find_geoname_id_by_ip was not generated because geoname_id is disabled for every selected IP family." >> "$file"
      echo >> "$file"
    fi
    cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_ip)(text);

SQL
    write_pg_build_location_functions "$file"
    if [[ -n "$(location_label_expr locale_param include_continent include_iso_code include_emoji)" ]]; then
      write_pg_location_labels_by_ip_function "$file"
    else
      echo "-- build_location_labels_by_ip was not generated because no configured location label columns can be returned." >> "$file"
      echo >> "$file"
    fi
    write_pg_location_batch_functions "$file"
  fi
}

write_100_cleanup() {
  local file="$RUN_DIR/100_cleanup_raw.sql"
  local locale version helper
  start_sql_file "$file" "Drop raw import and helper tables after a successful promote"
  if is_location_family; then
    for locale in "${LOAD_LOCALES[@]}"; do
      echo "DROP TABLE IF EXISTS $(ident "$(raw_location_table "$locale")");" >> "$file"
    done
  fi
  for version in "${IP_VERSIONS[@]}"; do
    echo "DROP TABLE IF EXISTS $(ident "$(raw_blocks_table "$version")");" >> "$file"
  done
  if has_enterprise_isp; then
    echo "DROP TABLE IF EXISTS $(ident "$(raw_isp_table)");" >> "$file"
  fi
  for helper in raw_emoji geoname_filter country_map subdivision1_map subdivision2_map timezone_map pow2; do
    echo "DROP TABLE IF EXISTS $(ident "$(helper_name "$helper")");" >> "$file"
  done
}

write_load_data() {
  local file="$RUN_DIR/load_data.sql"
  if sql_file_append_mode && [[ -f "$file" ]]; then
    debug_log "skip: load_data.sql already exists"
    return 0
  fi
  : > "$file"
  echo "-- Generated load script. Run it from this directory." >> "$file"
  if [[ "$DBMS" == "mysql" ]]; then
    cat >> "$file" <<SQL
SET NAMES utf8mb4;
-- MySQL DDL statements in the included files perform implicit commits.
-- LOAD DATA and INSERT batches are wrapped in explicit transactions where possible.
SOURCE 00_create_raw.sql
SOURCE 10_load_raw.sql
SOURCE 20_transform_stage.sql
SOURCE 90_indexes_stage.sql
SOURCE 100_cleanup_raw.sql
SOURCE 98_promote.sql
SOURCE 99_routines.sql
SQL
  else
    cat >> "$file" <<SQL
SET client_encoding TO 'UTF8';
BEGIN;
\\i 00_create_raw.sql
\\i 10_load_raw.sql
\\i 20_transform_stage.sql
\\i 90_indexes_stage.sql
\\i 98_promote.sql
\\i 99_routines.sql
\\i 100_cleanup_raw.sql
COMMIT;
SQL
  fi
}

write_loader() {
  local file="$RUN_DIR/loader.sh"
  local db_command_q=""
  if sql_file_append_mode && [[ -f "$file" ]]; then
    debug_log "skip: loader.sh already exists"
    return 0
  fi
  : > "$file"
  cat >> "$file" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

info() {
  printf '%s\n' "$*"
}

LOADER_DIR="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)"
SQL_FILES=(
  00_create_raw.sql
  10_load_raw.sql
  20_transform_stage.sql
  90_indexes_stage.sql
  98_promote.sql
  99_routines.sql
  100_cleanup_raw.sql
  load_data.sql
)
SQL_PATHS=()
for sql_file in "${SQL_FILES[@]}"; do
  if [[ ! -f "$LOADER_DIR/$sql_file" ]]; then
    info "Missing generated SQL file: $LOADER_DIR/$sql_file" >&2
    exit 1
  fi
  SQL_PATHS+=("$LOADER_DIR/$sql_file")
done

# Constraint and index names can survive table promotion. Replace every run ID
# embedded at generation time so that the same package can be loaded repeatedly.
GENERATED_RUN_IDS=()
mapfile -t GENERATED_RUN_IDS < <(
  awk '
    {
      rest = $0
      while (match(rest, /l[[:digit:]]{12}_[[:digit:]]+/)) {
        run_id = substr(rest, RSTART, RLENGTH)
        if (!seen[run_id]++) {
          print run_id
        }
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
  ' "${SQL_PATHS[@]}"
)

RUNTIME_RUN_IDS=()
RUN_EPOCH="$(date +%s)"
printf -v RUN_PID_HEX '%x' "$BASHPID"
printf -v RUN_EPOCH_HEX '%x' "$RUN_EPOCH"
for run_index in "${!GENERATED_RUN_IDS[@]}"; do
  generated_run_id="${GENERATED_RUN_IDS[$run_index]}"
  printf -v run_sequence_hex '%x' "$((run_index + 1))"
  runtime_run_id="r${run_sequence_hex}${RUN_PID_HEX}${RUN_EPOCH_HEX}"
  if (( ${#runtime_run_id} > ${#generated_run_id} )); then
    runtime_run_id="${runtime_run_id:0:${#generated_run_id}}"
  fi
  for existing_run_id in "${RUNTIME_RUN_IDS[@]}"; do
    if [[ "$runtime_run_id" == "$existing_run_id" ]]; then
      info "Could not create distinct runtime SQL run IDs" >&2
      exit 1
    fi
  done
  RUNTIME_RUN_IDS+=("$runtime_run_id")
done

RUNTIME_SQL_DIR="$(mktemp -d)"
cleanup_runtime_sql() {
  local sql_file
  for sql_file in "${SQL_FILES[@]}"; do
    rm -f -- "$RUNTIME_SQL_DIR/$sql_file"
  done
  rmdir -- "$RUNTIME_SQL_DIR" 2>/dev/null || true
}
trap cleanup_runtime_sql EXIT

for sql_file in "${SQL_FILES[@]}"; do
  while IFS= read -r sql_line || [[ -n "$sql_line" ]]; do
    for run_index in "${!GENERATED_RUN_IDS[@]}"; do
      sql_line="${sql_line//${GENERATED_RUN_IDS[$run_index]}/${RUNTIME_RUN_IDS[$run_index]}}"
    done
    printf '%s\n' "$sql_line"
  done < "$LOADER_DIR/$sql_file" > "$RUNTIME_SQL_DIR/$sql_file"
done

cd "$RUNTIME_SQL_DIR" || exit
SH
  if [[ "$DBMS" == "mysql" ]]; then
    printf -v db_command_q '%q' "$MYSQL_COMMAND"
    cat >> "$file" <<SH
MYSQL_HOST="$MYSQL_HOST"
MYSQL_PORT="$MYSQL_PORT"
MYSQL_USER="$MYSQL_USER"
export MYSQL_PWD="\${MYSQL_PWD:-$MYSQL_PASSWORD}"
START_SECONDS="\$(date +%s)"
info "Importing..."
set +e
$db_command_q --local-infile=1 --host="\$MYSQL_HOST" --port="\$MYSQL_PORT" --user="\$MYSQL_USER" $MYSQL_EXTRA_ARGS < load_data.sql
STATUS="\$?"
set -e
END_SECONDS="\$(date +%s)"
ELAPSED=\$((END_SECONDS - START_SECONDS))
if [[ "\$STATUS" -eq 0 ]]; then
  info "Complete in \$((ELAPSED / 60))m \$((ELAPSED % 60))s"
else
  info "Failed in \$((ELAPSED / 60))m \$((ELAPSED % 60))s"
fi
exit "\$STATUS"
SH
  else
    printf -v db_command_q '%q' "$POSTGRESQL_COMMAND"
    cat >> "$file" <<SH
PGHOST="$POSTGRESQL_HOST"
PGPORT="$POSTGRESQL_PORT"
PGUSER="$POSTGRESQL_USER"
PGDATABASE="$POSTGRESQL_DATABASE"
export PGPASSWORD="\${PGPASSWORD:-$POSTGRESQL_PASSWORD}"
START_SECONDS="\$(date +%s)"
info "Importing..."
set +e
$db_command_q --host="\$PGHOST" --port="\$PGPORT" --username="\$PGUSER" --dbname="\$PGDATABASE" -v ON_ERROR_STOP=1 $POSTGRESQL_EXTRA_ARGS -f load_data.sql
STATUS="\$?"
set -e
END_SECONDS="\$(date +%s)"
ELAPSED=\$((END_SECONDS - START_SECONDS))
if [[ "\$STATUS" -eq 0 ]]; then
  info "Complete in \$((ELAPSED / 60))m \$((ELAPSED % 60))s"
else
  info "Failed in \$((ELAPSED / 60))m \$((ELAPSED % 60))s"
fi
exit "\$STATUS"
SH
  fi
  chmod +x "$file" >/dev/null 2>&1 || true
}

make_output_archive() {
  local archive_name="$1"
  [[ -n "$archive_name" ]] || return 0
  if sql_file_append_mode && [[ "${MAXMIND_CSV2SQL_FINAL_OUTPUT:-true}" != "true" ]]; then
    debug_log "skip: output archive is delayed until the final edition"
    return 0
  fi
  archive_name="$(basename "$archive_name")"
  [[ "$archive_name" == *.zip ]] || archive_name="$archive_name.zip"
  local archive_path="$RUN_DIR/$archive_name"
  rm -f -- "$archive_path"
  if command -v zip >/dev/null 2>&1; then
    (
      cd "$RUN_DIR" || exit
      zip -qr "$archive_name" . -x "$archive_name"
    )
    info "Archive with generated import package: $archive_path"
    return 0
  fi
  info "Archive was requested, but zip was not found; generated files were left unpacked"
}
