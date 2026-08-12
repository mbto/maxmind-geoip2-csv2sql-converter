# https://github.com/mbto/maxmind-csv2sql-converter v1.2
declare -g DBMS MYSQL_COMMAND MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_EXTRA_ARGS MYSQL_ROUTINE_DEFINER
declare -g POSTGRESQL_COMMAND POSTGRESQL_HOST POSTGRESQL_PORT POSTGRESQL_USER POSTGRESQL_DATABASE POSTGRESQL_PASSWORD POSTGRESQL_EXTRA_ARGS
: "${DBMS:?DBMS must be set before sourcing default generator functions}"

declare -gA CONFIGURED_COLUMN_ENABLED_CACHE=()
declare -gA COLUMN_ENABLED_CACHE=()
declare -gA FINAL_TABLE_ENABLED_CACHE=()
declare -gA BLOCK_TABLE_HAS_OUTPUT_COLUMN_CACHE=()
declare -gA LOCATION_MIX_EXPR_CACHE=()
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
    allowed="network,$ip_range_columns,v_geoname_id"
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
    require_column_enabled "$table" v_geoname_id
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
    v_geoname_id|geoname_id|registered_country_geoname_id|represented_country_geoname_id|accuracy_radius|autonomous_system_number|isp_id|anonymizer_confidence|ipv4_24|ipv4_32|ipv6_32|ipv6_48|ipv6_64) echo "INT UNSIGNED DEFAULT NULL" ;;
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
    v_geoname_id|geoname_id|registered_country_geoname_id|represented_country_geoname_id|accuracy_radius|autonomous_system_number|isp_id|anonymizer_confidence|ipv4_24|ipv4_32|ipv6_32|ipv6_48|ipv6_64) echo "integer DEFAULT NULL" ;;
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
        is_location_family && lines+=("  $(mysql_ident v_geoname_id) INT UNSIGNED NOT NULL COMMENT 'One of valid geoname_id (from v_geoname_id_priority_columns .convert section)'")
        append_block_header_columns lines "$table" network
        lines+=("  PRIMARY KEY ($(mysql_ident network))")
        emit_create_table_sql "$q" "${lines[@]}"
        ;;
      postgresql:ipv4|postgresql:ipv6)
        lines=()
        lines+=("  $(pg_ident network) cidr NOT NULL")
        lines+=("  $(pg_ident start_ip) inet NOT NULL")
        lines+=("  $(pg_ident last_ip) inet NOT NULL")
        is_location_family && lines+=("  $(pg_ident v_geoname_id) integer NOT NULL")
        append_block_header_columns lines "$table" network
        lines+=("  PRIMARY KEY ($(pg_ident network))")
        emit_create_table_sql "$q" "${lines[@]}"
        if is_location_family; then
          echo "COMMENT ON COLUMN $q.$(pg_ident v_geoname_id) IS 'One of valid geoname_id (from v_geoname_id_priority_columns .convert section)';"
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

vgeo_case_expr() {
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
  local raw table prefix_bits start_expr last_expr pow_join candidate where_candidate cols selects cols_csv selects_sql field alias
  raw="$(raw_blocks_table "$version")"
  table="ipv$version"
  candidate="$(vgeo_case_expr)"
  where_candidate="$candidate IS NOT NULL"
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
    cols+=(start_ip last_ip v_geoname_id)
    selects+=("$start_expr" "$last_expr" "$candidate")
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
    cols+=(start_ip last_ip v_geoname_id)
    selects+=("$start_expr" "$last_expr" "$candidate")
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
WHERE $where_candidate;

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
              "ADD KEY $(ident "ix_${RUN_ID}_${table}_vgeo") ($(ident v_geoname_id))"
              "ADD CONSTRAINT $(ident "fk_${RUN_ID}_${table}_vgeo") FOREIGN KEY ($(ident v_geoname_id)) REFERENCES $(ident "$(stage_name "$ref")") ($(ident geoname_id)) ON UPDATE CASCADE ON DELETE CASCADE"
            )
            if column_enabled "$table" geoname_id; then
              clauses+=("ADD KEY $(ident "ix_${RUN_ID}_${table}_geo") ($(ident geoname_id))")
              clauses+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_${table}_geo") FOREIGN KEY ($(ident geoname_id)) REFERENCES $(ident "$(stage_name "$ref")") ($(ident geoname_id)) ON UPDATE CASCADE ON DELETE CASCADE")
            fi
            if column_enabled "$table" registered_country_geoname_id; then
              clauses+=("ADD KEY $(ident "ix_${RUN_ID}_${table}_rgeo") ($(ident registered_country_geoname_id))")
              if [[ "$ARCHIVE_EDITION_KIND" == "Country" ]]; then
                clauses+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_${table}_rgeo") FOREIGN KEY ($(ident registered_country_geoname_id)) REFERENCES $(ident "$(stage_name "$ref")") ($(ident geoname_id)) ON UPDATE CASCADE ON DELETE CASCADE")
              fi
            fi
            if column_enabled "$table" represented_country_geoname_id; then
              clauses+=("ADD KEY $(ident "ix_${RUN_ID}_${table}_reprgeo") ($(ident represented_country_geoname_id))")
              if [[ "$ARCHIVE_EDITION_KIND" == "Country" ]]; then
                clauses+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_${table}_reprgeo") FOREIGN KEY ($(ident represented_country_geoname_id)) REFERENCES $(ident "$(stage_name "$ref")") ($(ident geoname_id)) ON UPDATE CASCADE ON DELETE CASCADE")
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
            echo "CREATE INDEX $(ident "ix_${RUN_ID}_${table}_vgeo") ON $(ident "$(stage_name "$table")") ($(ident v_geoname_id));" >> "$file"
            constraints=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_${table}_vgeo") FOREIGN KEY ($(ident v_geoname_id)) REFERENCES $(ident "$(stage_name "$ref")") ($(ident geoname_id)) ON UPDATE CASCADE ON DELETE CASCADE")
            if column_enabled "$table" geoname_id; then
              echo "CREATE INDEX $(ident "ix_${RUN_ID}_${table}_geo") ON $(ident "$(stage_name "$table")") ($(ident geoname_id));" >> "$file"
              constraints+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_${table}_geo") FOREIGN KEY ($(ident geoname_id)) REFERENCES $(ident "$(stage_name "$ref")") ($(ident geoname_id)) ON UPDATE CASCADE ON DELETE CASCADE")
            fi
            if column_enabled "$table" registered_country_geoname_id; then
              echo "CREATE INDEX $(ident "ix_${RUN_ID}_${table}_rgeo") ON $(ident "$(stage_name "$table")") ($(ident registered_country_geoname_id));" >> "$file"
              if [[ "$ARCHIVE_EDITION_KIND" == "Country" ]]; then
                constraints+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_${table}_rgeo") FOREIGN KEY ($(ident registered_country_geoname_id)) REFERENCES $(ident "$(stage_name "$ref")") ($(ident geoname_id)) ON UPDATE CASCADE ON DELETE CASCADE")
              fi
            fi
            if column_enabled "$table" represented_country_geoname_id; then
              echo "CREATE INDEX $(ident "ix_${RUN_ID}_${table}_reprgeo") ON $(ident "$(stage_name "$table")") ($(ident represented_country_geoname_id));" >> "$file"
              if [[ "$ARCHIVE_EDITION_KIND" == "Country" ]]; then
                constraints+=("ADD CONSTRAINT $(ident "fk_${RUN_ID}_${table}_reprgeo") FOREIGN KEY ($(ident represented_country_geoname_id)) REFERENCES $(ident "$(stage_name "$ref")") ($(ident geoname_id)) ON UPDATE CASCADE ON DELETE CASCADE")
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
  echo "ALTER TABLE $(mysql_ident "$table") ADD CONSTRAINT $(mysql_ident "fk_${suffix}") FOREIGN KEY ($(mysql_ident "$column")) REFERENCES $(mysql_ident "$ref_table") ($(mysql_ident "$ref_column")) ON UPDATE CASCADE ON DELETE CASCADE;" >> "$file"
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
      mysql_promote_drop_fk_sql "$file" "$table" "${table}_vgeo"
    else
      mysql_promote_add_fk_sql "$file" "$table" "${table}_vgeo" v_geoname_id "$ref" geoname_id
    fi
    if column_enabled "$table" geoname_id; then
      if [[ "$action" == "drop" ]]; then
        mysql_promote_drop_fk_sql "$file" "$table" "${table}_geo"
      else
        mysql_promote_add_fk_sql "$file" "$table" "${table}_geo" geoname_id "$ref" geoname_id
      fi
    fi
    if [[ "$ARCHIVE_EDITION_KIND" == "Country" ]] && column_enabled "$table" registered_country_geoname_id; then
      if [[ "$action" == "drop" ]]; then
        mysql_promote_drop_fk_sql "$file" "$table" "${table}_rgeo"
      else
        mysql_promote_add_fk_sql "$file" "$table" "${table}_rgeo" registered_country_geoname_id "$ref" geoname_id
      fi
    fi
    if [[ "$ARCHIVE_EDITION_KIND" == "Country" ]] && column_enabled "$table" represented_country_geoname_id; then
      if [[ "$action" == "drop" ]]; then
        mysql_promote_drop_fk_sql "$file" "$table" "${table}_reprgeo"
      else
        mysql_promote_add_fk_sql "$file" "$table" "${table}_reprgeo" represented_country_geoname_id "$ref" geoname_id
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
    mysql_promote_rename_index_sql "$file" "$table" "${table}_vgeo"
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
  local mix="$5"
  if [[ "$mix" == "true" ]]; then
    mix_locale_expr "$alias" "$table" "$base"
  elif column_enabled "$table" "${base}_$locale"; then
    printf '%s.%s' "$alias" "$(ident "${base}_$locale")"
  fi
}

mix_locale_expr() {
  local alias="$1"
  local table="$2"
  local base="$3"
  local locale exprs=()
  for preferred in ru en; do
    if array_contains "$preferred" "${SELECTED_LOCALES[@]}" && column_enabled "$table" "${base}_$preferred"; then
      exprs+=("$alias.$(ident "${base}_$preferred")")
    fi
  done
  for locale in "${SELECTED_LOCALES[@]}"; do
    [[ "$locale" == "ru" || "$locale" == "en" ]] && continue
    if column_enabled "$table" "${base}_$locale"; then
      exprs+=("$alias.$(ident "${base}_$locale")")
    fi
  done
  [[ "${#exprs[@]}" -gt 0 ]] || return 0
  printf 'COALESCE('
  join_sql_items ", " "${exprs[@]}"
  printf ')'
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

country_mix_label_expr() {
  local mode="$1"
  local c_name="$2"
  local c_iso="" c_emoji="" iso_box="" label=""
  case "$mode" in
    emoji)
      if [[ -n "$c_name" ]] && column_enabled country emoji; then
        c_emoji="c.$(ident emoji)"
        label="$(concat_ws_expr "' '" "NULLIF($c_emoji, '')" "$c_name")"
        printf "CASE WHEN append_emoji = 1 THEN %s ELSE %s END" "$label" "$c_name"
      elif column_enabled country emoji; then
        c_emoji="c.$(ident emoji)"
        printf "CASE WHEN append_emoji = 1 THEN NULLIF(%s, '') ELSE NULL END" "$c_emoji"
      elif [[ -n "$c_name" ]]; then
        printf '%s' "$c_name"
      fi
      ;;
    iso)
      if column_enabled country iso_code; then
        c_iso="c.$(ident iso_code)"
        iso_box="$(concat_expr "'['" "$c_iso" "']'")"
        if [[ -n "$c_name" ]]; then
          label="$(concat_ws_expr "' '" "$iso_box" "$c_name")"
          printf "CASE WHEN NULLIF(%s, '') IS NULL THEN %s ELSE %s END" "$c_iso" "$c_name" "$label"
        else
          printf "CASE WHEN NULLIF(%s, '') IS NULL THEN NULL ELSE %s END" "$c_iso" "$iso_box"
        fi
      elif [[ -n "$c_name" ]]; then
        printf '%s' "$c_name"
      fi
      ;;
    *)
      die "Unsupported country mix label mode: $mode"
      ;;
  esac
}

city_location_mix_expr() {
  local country_mode="$1"
  local c_cont="" c_name="" c_label="" sd1="" sd2="" ci="" parts=() compares=()

  if column_enabled city country_id; then
    c_cont="$(mix_locale_expr c country continent_name)"
    c_name="$(mix_locale_expr c country name)"
    c_label="$(country_mix_label_expr "$country_mode" "$c_name")"
  fi
  [[ -n "$c_cont" ]] && parts+=("$c_cont")
  [[ -n "$c_label" ]] && parts+=("$c_label")

  if column_enabled city subdivision1_id; then
    sd1="$(mix_locale_expr sd1 subdivision1 name)"
  fi
  if column_enabled city subdivision2_id; then
    sd2="$(mix_locale_expr sd2 subdivision2 name)"
  fi
  ci="$(mix_locale_expr ci city name)"

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

  [[ "${#parts[@]}" -gt 0 ]] || return 0
  concat_ws_expr "' - '" "${parts[@]}"
}

country_location_mix_expr() {
  local country_mode="$1"
  local c_cont="" c_name="" c_label="" parts=()

  c_cont="$(mix_locale_expr c country continent_name)"
  c_name="$(mix_locale_expr c country name)"
  c_label="$(country_mix_label_expr "$country_mode" "$c_name")"

  [[ -n "$c_cont" ]] && parts+=("$c_cont")
  [[ -n "$c_label" ]] && parts+=("$c_label")

  [[ "${#parts[@]}" -gt 0 ]] || return 0
  concat_ws_expr "' - '" "${parts[@]}"
}

build_location_mix_expr() {
  local country_mode="$1"
  local expr
  if [[ -v 'LOCATION_MIX_EXPR_CACHE[$country_mode]' ]]; then
    [[ -n "${LOCATION_MIX_EXPR_CACHE[$country_mode]}" ]] && printf '%s' "${LOCATION_MIX_EXPR_CACHE[$country_mode]}"
    return
  fi
  if is_city_location; then
    expr="$(city_location_mix_expr "$country_mode")"
  else
    expr="$(country_location_mix_expr "$country_mode")"
  fi
  LOCATION_MIX_EXPR_CACHE[$country_mode]="$expr"
  [[ -n "$expr" ]] && printf '%s' "$expr"
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

location_expr() {
  local kind="$1"
  local locale="$2"
  local mix="$3"
  local fn c_cont="" c_name="" sd1="" sd2="" ci="" parts=() compares=()
  [[ "$DBMS" == "mysql" ]] && fn="CONCAT_WS" || fn="concat_ws"

  if [[ "$kind" == "country" ]] || { [[ "$kind" == "city" ]] && column_enabled city country_id; }; then
    c_cont="$(locale_text_expr c country continent_name "$locale" "$mix")"
    c_name="$(locale_text_expr c country name "$locale" "$mix")"
  fi
  [[ -n "$c_cont" ]] && parts+=("$c_cont")
  [[ -n "$c_name" ]] && parts+=("$c_name")

  if [[ "$kind" == "city" ]]; then
    if column_enabled city subdivision1_id; then
      sd1="$(locale_text_expr sd1 subdivision1 name "$locale" "$mix")"
    fi
    if column_enabled city subdivision2_id; then
      sd2="$(locale_text_expr sd2 subdivision2 name "$locale" "$mix")"
    fi
    ci="$(locale_text_expr ci city name "$locale" "$mix")"

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
  printf "%s(' - ', " "$fn"
  join_sql_items ", " "${parts[@]}"
  printf ")"
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
    expr="$(location_expr "$kind" "$locale" false)"
    if [[ -n "$expr" ]]; then
      names_ref+=("location_$(locale_alias "$locale")")
      exprs_ref+=("$expr")
      types_ref+=("text")
    fi
  done
  expr="$(location_expr "$kind" "" true)"
  if [[ -n "$expr" ]]; then
    names_ref+=(location_mix)
    exprs_ref+=("$expr")
    types_ref+=("text")
  fi
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

  expr="$(build_location_mix_expr emoji)"
  if [[ -n "$expr" ]]; then
    write_mysql_build_location_function "$file" "$definer" build_location_mix "geoname_id_param INT UNSIGNED, append_emoji INT UNSIGNED" "$expr"
  else
    cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(mysql_ident build_location_mix)\$\$
-- build_location_mix was not generated because no configured output columns can be returned.

SQL
  fi

  expr="$(build_location_mix_expr iso)"
  if [[ -n "$expr" ]]; then
    write_mysql_build_location_function "$file" "$definer" build_location_mix_with_iso_code "geoname_id_param INT UNSIGNED" "$expr"
  else
    cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(mysql_ident build_location_mix_with_iso_code)\$\$
-- build_location_mix_with_iso_code was not generated because no configured output columns can be returned.

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

  expr="$(build_location_mix_expr emoji)"
  if [[ -n "$expr" ]]; then
    write_pg_build_location_function "$file" build_location_mix "integer, integer" "geoname_id_param integer, append_emoji integer" "$expr"
  else
    cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident build_location_mix)(integer, integer);

-- build_location_mix was not generated because no configured output columns can be returned.

SQL
  fi

  expr="$(build_location_mix_expr iso)"
  if [[ -n "$expr" ]]; then
    write_pg_build_location_function "$file" build_location_mix_with_iso_code "integer" "geoname_id_param integer" "$expr"
  else
    cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident build_location_mix_with_iso_code)(integer);

-- build_location_mix_with_iso_code was not generated because no configured output columns can be returned.

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
  if is_location_family && column_enabled "$table" v_geoname_id; then
    columns+=(v_geoname_id)
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
  if [[ "$wanted" == "v_geoname_id" ]]; then
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

mysql_network_lookup_temp_columns_sql() {
  local cols=("$@")
  local lines=(
    "        $(mysql_ident ord) INT UNSIGNED NOT NULL"
    "        $(mysql_ident ip) VARCHAR(45) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL"
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
                WHERE b.$(ident start_ip) <= $value_expr
                ORDER BY b.$(ident start_ip) DESC
                LIMIT 1
            ) AS candidate
            WHERE candidate.$(ident __last_ip) >= $value_expr;
SQL
}

write_mysql_network_lookup_procedure() {
  local file="$1"
  local definer="$2"
  local has4="$3"
  local has6="$4"
  local cols4=() cols6=() fallback_cols=()
  local empty_select4="" empty_select6="" fallback_empty_select
  if [[ "$has4" == "true" ]]; then
    mapfile -t cols4 < <(network_lookup_table_columns ipv4)
    empty_select4="$(mysql_network_lookup_empty_select_sql "${cols4[@]}")"
  fi
  if [[ "$has6" == "true" ]]; then
    mapfile -t cols6 < <(network_lookup_table_columns ipv6)
    empty_select6="$(mysql_network_lookup_empty_select_sql "${cols6[@]}")"
  fi
  mapfile -t fallback_cols < <(network_lookup_columns)
  fallback_empty_select="$(mysql_network_lookup_empty_select_sql "${fallback_cols[@]}")"
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
    IF INSTR(ip, ':') > 0 THEN
SQL
  if [[ "$has6" == "true" ]]; then
    cat >> "$file" <<SQL
        SET ip6 = $(mysql_ident inet6_aton_decimal)(ip);
        IF ip6 IS NULL THEN
            SELECT $empty_select6 WHERE FALSE;
        ELSE
SQL
    write_mysql_network_lookup_branch "$file" ipv6 ip6 "${cols6[@]}"
    cat >> "$file" <<SQL
        END IF;
SQL
  else
    cat >> "$file" <<SQL
        SELECT $fallback_empty_select WHERE FALSE;
SQL
  fi
  cat >> "$file" <<SQL
    ELSE
SQL
  if [[ "$has4" == "true" ]]; then
    cat >> "$file" <<SQL
        SET ip4 = INET_ATON(ip);
        IF ip4 IS NULL THEN
            SELECT $empty_select4 WHERE FALSE;
        ELSE
SQL
    write_mysql_network_lookup_branch "$file" ipv4 ip4 "${cols4[@]}"
    cat >> "$file" <<SQL
        END IF;
SQL
  else
    cat >> "$file" <<SQL
        SELECT $fallback_empty_select WHERE FALSE;
SQL
  fi
  cat >> "$file" <<SQL
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

write_pg_network_lookup_function() {
  local file="$1"
  local has4="$2"
  local has6="$3"
  local cols=()
  local return_cols
  mapfile -t cols < <(network_lookup_columns)
  return_cols="$(pg_network_lookup_return_cols_sql "${cols[@]}")"
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
    v_ip := p_ip::inet;
SQL
  if [[ "$has4" == "true" ]]; then
    cat >> "$file" <<SQL
    IF family(v_ip) = 4 THEN
SQL
    write_pg_network_lookup_branch "$file" ipv4
    cat >> "$file" <<SQL
    END IF;
SQL
  fi
  if [[ "$has6" == "true" ]]; then
    cat >> "$file" <<SQL
    IF family(v_ip) = 6 THEN
SQL
    write_pg_network_lookup_branch "$file" ipv6
    cat >> "$file" <<SQL
    END IF;
SQL
  fi
  cat >> "$file" <<SQL
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
            SET $update_assignments
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

    SET idx = 0;
    WHILE idx < item_count DO
        SET v_ord = idx + 1;
        SET v_ip = CASE
            WHEN JSON_TYPE(JSON_EXTRACT(ips_json, CONCAT('\$[', idx, ']'))) = 'NULL' THEN NULL
            ELSE JSON_UNQUOTE(JSON_EXTRACT(ips_json, CONCAT('\$[', idx, ']')))
        END;
        SET v_ip4 = NULL;
        SET v_ip6 = NULL;

        INSERT INTO $(mysql_ident _find_networks_by_ips_json_result) ($(ident ord), $(ident ip)) VALUES (v_ord, v_ip);

        IF v_ip IS NOT NULL THEN
SQL
  if [[ "$branch_has4" == "true" && "$branch_has6" == "true" ]]; then
    cat >> "$file" <<SQL
            IF INSTR(v_ip, ':') > 0 THEN
SQL
    cat >> "$file" <<SQL
                SET v_ip6 = $(mysql_ident inet6_aton_decimal)(v_ip);
                IF v_ip6 IS NOT NULL THEN
SQL
    write_mysql_network_lookup_batch_update_branch "$file" ipv6 v_ip6 "${cols[@]}"
    cat >> "$file" <<SQL
                END IF;
SQL
  cat >> "$file" <<SQL
            ELSE
SQL
    cat >> "$file" <<SQL
                SET v_ip4 = INET_ATON(v_ip);
                IF v_ip4 IS NOT NULL THEN
SQL
    write_mysql_network_lookup_batch_update_branch "$file" ipv4 v_ip4 "${cols[@]}"
    cat >> "$file" <<SQL
                END IF;
SQL
    cat >> "$file" <<SQL
            END IF;
SQL
  elif [[ "$branch_has6" == "true" ]]; then
    cat >> "$file" <<SQL
            IF INSTR(v_ip, ':') > 0 THEN
                SET v_ip6 = $(mysql_ident inet6_aton_decimal)(v_ip);
                IF v_ip6 IS NOT NULL THEN
SQL
    write_mysql_network_lookup_batch_update_branch "$file" ipv6 v_ip6 "${cols[@]}"
    cat >> "$file" <<SQL
                END IF;
            END IF;
SQL
  elif [[ "$branch_has4" == "true" ]]; then
    cat >> "$file" <<SQL
            IF INSTR(v_ip, ':') = 0 THEN
                SET v_ip4 = INET_ATON(v_ip);
                IF v_ip4 IS NOT NULL THEN
SQL
    write_mysql_network_lookup_batch_update_branch "$file" ipv4 v_ip4 "${cols[@]}"
    cat >> "$file" <<SQL
                END IF;
            END IF;
SQL
  fi
  cat >> "$file" <<SQL
        END IF;

        SET idx = idx + 1;
    END WHILE;

    SELECT r.$(ident ord) AS $(ident ord), r.$(ident ip) AS $(ident ip), $batch_selects
    FROM $(mysql_ident _find_networks_by_ips_json_result) r
    ORDER BY r.$(ident ord);

    DROP TEMPORARY TABLE IF EXISTS $(mysql_ident _find_networks_by_ips_json_result);
SQL
}

write_mysql_network_lookup_batch_detect_input_sql() {
  local file="$1"
  cat >> "$file" <<SQL
    SET idx = 0;
    WHILE idx < item_count DO
        SET v_ip = CASE
            WHEN JSON_TYPE(JSON_EXTRACT(ips_json, CONCAT('\$[', idx, ']'))) = 'NULL' THEN NULL
            ELSE JSON_UNQUOTE(JSON_EXTRACT(ips_json, CONCAT('\$[', idx, ']')))
        END;
        SET v_ip4 = NULL;
        SET v_ip6 = NULL;

        IF v_ip IS NOT NULL THEN
            IF INSTR(v_ip, ':') > 0 THEN
                SET v_ip6 = $(mysql_ident inet6_aton_decimal)(v_ip);
                IF v_ip6 IS NOT NULL THEN
                    SET v_has_ipv6 = 1;
                END IF;
            ELSE
                SET v_ip4 = INET_ATON(v_ip);
                IF v_ip4 IS NOT NULL THEN
                    SET v_has_ipv4 = 1;
                END IF;
            END IF;
        END IF;

        SET idx = idx + 1;
    END WHILE;
SQL
}

write_mysql_network_lookup_batch_procedure() {
  local file="$1"
  local definer="$2"
  local has4="$3"
  local has6="$4"
  local cols=() cols4=() cols6=()
  mapfile -t cols < <(network_lookup_columns)
  [[ "$has4" == "true" ]] && mapfile -t cols4 < <(network_lookup_table_columns ipv4)
  [[ "$has6" == "true" ]] && mapfile -t cols6 < <(network_lookup_table_columns ipv6)
  cat >> "$file" <<SQL
DELIMITER \$\$
DROP PROCEDURE IF EXISTS $(mysql_ident find_networks_by_ips_json)\$\$
CREATE ${definer}PROCEDURE $(mysql_ident find_networks_by_ips_json)(ips_json JSON)
    READS SQL DATA
BEGIN
    DECLARE idx INT UNSIGNED DEFAULT 0;
    DECLARE item_count INT UNSIGNED DEFAULT 0;
    DECLARE v_ord INT UNSIGNED DEFAULT 0;
    DECLARE v_ip VARCHAR(45) DEFAULT NULL;
    DECLARE v_ip4 INT UNSIGNED DEFAULT NULL;
    DECLARE v_ip6 DECIMAL(39,0) DEFAULT NULL;
    DECLARE v_has_ipv4 TINYINT UNSIGNED DEFAULT 0;
    DECLARE v_has_ipv6 TINYINT UNSIGNED DEFAULT 0;

    SET item_count = CASE
        WHEN JSON_TYPE(ips_json) = 'ARRAY' THEN COALESCE(JSON_LENGTH(ips_json), 0)
        ELSE 0
    END;

SQL
  if [[ "$has4" == "true" && "$has6" == "true" ]]; then
    write_mysql_network_lookup_batch_detect_input_sql "$file"
    cat >> "$file" <<SQL

    IF v_has_ipv4 = 1 AND v_has_ipv6 = 0 THEN
SQL
    write_mysql_network_lookup_batch_body "$file" true false "${cols4[@]}"
    cat >> "$file" <<SQL
    ELSEIF v_has_ipv4 = 0 AND v_has_ipv6 = 1 THEN
SQL
    write_mysql_network_lookup_batch_body "$file" false true "${cols6[@]}"
    cat >> "$file" <<SQL
    ELSE
SQL
    write_mysql_network_lookup_batch_body "$file" true true "${cols[@]}"
    cat >> "$file" <<SQL
    END IF;
SQL
  elif [[ "$has4" == "true" ]]; then
    write_mysql_network_lookup_batch_body "$file" true false "${cols4[@]}"
  elif [[ "$has6" == "true" ]]; then
    write_mysql_network_lookup_batch_body "$file" false true "${cols6[@]}"
  else
    write_mysql_network_lookup_batch_body "$file" false false "${cols[@]}"
  fi
  cat >> "$file" <<SQL
END\$\$
DELIMITER ;

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
  return_cols="$(pg_ident ord) integer, $(pg_ident ip) text"
  return_cols="${return_cols}, $(pg_network_lookup_return_cols_sql "${cols[@]}")"
  batch_selects="$(network_lookup_alias_selects_sql c "${cols[@]}")"
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident "$name")(jsonb);

CREATE OR REPLACE FUNCTION $(pg_ident "$name")(p_ips jsonb)
RETURNS TABLE($return_cols)
LANGUAGE sql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
WITH input AS (
    SELECT item.$(ident ord)::integer AS $(ident ord),
           item.$(ident ip) AS $(ident ip),
           item.$(ident ip)::inet AS $(ident parsed_ip)
    FROM jsonb_array_elements_text(p_ips) WITH ORDINALITY AS item($(ident ip), $(ident ord))
)
SELECT i.$(ident ord), i.$(ident ip), $batch_selects
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
  write_pg_network_lookup_batch_function_named "$file" find_networks_by_ips_json "$has4" "$has6" "${cols[@]}"
}

write_pg_network_lookup_batch_family_functions() {
  local file="$1"
  local has4="$2"
  local has6="$3"
  local cols4=() cols6=()
  if [[ "$has4" == "true" ]]; then
    mapfile -t cols4 < <(network_lookup_table_columns ipv4)
    write_pg_network_lookup_batch_function_named "$file" find_ipv4_networks_by_ips_json true false "${cols4[@]}"
  else
    echo "DROP FUNCTION IF EXISTS $(pg_ident find_ipv4_networks_by_ips_json)(jsonb);" >> "$file"
    echo >> "$file"
  fi
  if [[ "$has6" == "true" ]]; then
    mapfile -t cols6 < <(network_lookup_table_columns ipv6)
    write_pg_network_lookup_batch_function_named "$file" find_ipv6_networks_by_ips_json false true "${cols6[@]}"
  else
    echo "DROP FUNCTION IF EXISTS $(pg_ident find_ipv6_networks_by_ips_json)(jsonb);" >> "$file"
    echo >> "$file"
  fi
}

write_mysql_batch_geoinfo_select_columns() {
  local file="$1"
  local include_ip="$2"
  local -n names_ref="$3"
  local -n exprs_ref="$4"
  local i
  echo "    SELECT" >> "$file"
  echo "        i.$(mysql_ident ord) AS $(mysql_ident ord)" >> "$file"
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
  local mix_expr iso_expr mix_select iso_select
  routine_select_parts routine_names routine_exprs routine_types
  cat >> "$file" <<SQL
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoname_ids_by_ips_json)\$\$
CREATE ${definer}PROCEDURE $(mysql_ident find_geoname_ids_by_ips_json)(ips_json JSON)
    READS SQL DATA
BEGIN
    WITH input AS (
        SELECT CAST(j.$(ident ord) AS UNSIGNED) AS $(ident ord),
               j.$(ident ip) AS $(ident ip),
               $(mysql_ident find_geoname_id_by_ip)(j.$(ident ip)) AS $(ident geoname_id)
        FROM JSON_TABLE(ips_json, '\$[*]' COLUMNS (
            $(ident ord) FOR ORDINALITY,
            $(ident ip) VARCHAR(45) PATH '\$'
        )) AS j
    )
    SELECT i.$(ident ord) AS $(ident ord), i.$(ident ip) AS $(ident ip), i.$(ident geoname_id) AS $(ident geoname_id)
    FROM input i
    ORDER BY i.$(ident ord);
END\$\$

DROP PROCEDURE IF EXISTS $(mysql_ident find_geoinfo_by_geoname_ids_json)\$\$
CREATE ${definer}PROCEDURE $(mysql_ident find_geoinfo_by_geoname_ids_json)(geoname_ids_json JSON)
    READS SQL DATA
BEGIN
    WITH input AS (
        SELECT CAST(j.$(ident ord) AS UNSIGNED) AS $(ident ord),
               CAST(j.$(ident geoname_id) AS UNSIGNED) AS $(ident geoname_id)
        FROM JSON_TABLE(geoname_ids_json, '\$[*]' COLUMNS (
            $(ident ord) FOR ORDINALITY,
            $(ident geoname_id) INT PATH '\$'
        )) AS j
    )
SQL
  write_mysql_batch_geoinfo_select_columns "$file" false routine_names routine_exprs
  write_geoname_lookup_from_input_sql "$file" "    " "i.$(ident geoname_id)"
  cat >> "$file" <<SQL
    ORDER BY i.$(ident ord);
END\$\$

DROP PROCEDURE IF EXISTS $(mysql_ident find_geoinfo_by_ips_json)\$\$
CREATE ${definer}PROCEDURE $(mysql_ident find_geoinfo_by_ips_json)(ips_json JSON)
    READS SQL DATA
BEGIN
    WITH input AS (
        SELECT CAST(j.$(ident ord) AS UNSIGNED) AS $(ident ord),
               j.$(ident ip) AS $(ident ip),
               $(mysql_ident find_geoname_id_by_ip)(j.$(ident ip)) AS $(ident geoname_id)
        FROM JSON_TABLE(ips_json, '\$[*]' COLUMNS (
            $(ident ord) FOR ORDINALITY,
            $(ident ip) VARCHAR(45) PATH '\$'
        )) AS j
    )
SQL
  write_mysql_batch_geoinfo_select_columns "$file" true routine_names routine_exprs
  write_geoname_lookup_from_input_sql "$file" "    " "i.$(ident geoname_id)"
  cat >> "$file" <<SQL
    ORDER BY i.$(ident ord);
END\$\$

SQL
  mix_expr="$(build_location_mix_expr emoji)"
  iso_expr="$(build_location_mix_expr iso)"
  if [[ -n "$mix_expr" ]]; then
    mix_select="$(mysql_ident build_location_mix)(i.$(mysql_ident geoname_id), append_emoji)"
  else
    mix_select="NULL"
  fi
  if [[ -n "$iso_expr" ]]; then
    iso_select="$(mysql_ident build_location_mix_with_iso_code)(i.$(mysql_ident geoname_id))"
  else
    iso_select="NULL"
  fi
  cat >> "$file" <<SQL
DROP PROCEDURE IF EXISTS $(mysql_ident build_location_mixes_by_geoname_ids_json)\$\$
CREATE ${definer}PROCEDURE $(mysql_ident build_location_mixes_by_geoname_ids_json)(geoname_ids_json JSON, append_emoji INT UNSIGNED)
    READS SQL DATA
BEGIN
    WITH input AS (
        SELECT CAST(j.$(ident ord) AS UNSIGNED) AS $(ident ord),
               CAST(j.$(ident geoname_id) AS UNSIGNED) AS $(ident geoname_id)
        FROM JSON_TABLE(geoname_ids_json, '\$[*]' COLUMNS (
            $(ident ord) FOR ORDINALITY,
            $(ident geoname_id) INT PATH '\$'
        )) AS j
    )
    SELECT i.$(ident ord) AS $(ident ord),
           i.$(ident geoname_id) AS $(ident geoname_id),
           $mix_select AS $(ident location_mix),
           $iso_select AS $(ident location_mix_iso)
    FROM input i
    ORDER BY i.$(ident ord);
END\$\$

SQL
}

write_pg_batch_geoinfo_select_columns() {
  local file="$1"
  local include_ip="$2"
  local -n names_ref="$3"
  local -n exprs_ref="$4"
  local i
  echo "SELECT" >> "$file"
  echo "    i.$(pg_ident ord)" >> "$file"
  if [[ "$include_ip" == "true" ]]; then
    echo "    , i.$(pg_ident ip)" >> "$file"
  fi
  echo "    , i.$(pg_ident geoname_id)" >> "$file"
  for ((i = 0; i < ${#names_ref[@]}; i++)); do
    printf "    , %s AS %s\n" "${exprs_ref[i]}" "$(pg_ident "${names_ref[i]}")" >> "$file"
  done
}

write_pg_location_batch_functions() {
  local file="$1"
  local routine_names=() routine_exprs=() routine_types=()
  local return_cols i mix_expr iso_expr mix_select iso_select
  routine_select_parts routine_names routine_exprs routine_types
  return_cols="$(pg_ident ord) integer, $(pg_ident ip) text, $(pg_ident geoname_id) integer"
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident find_geoname_ids_by_ips_json)(jsonb);

CREATE OR REPLACE FUNCTION $(pg_ident find_geoname_ids_by_ips_json)(p_ips jsonb)
RETURNS TABLE($return_cols)
LANGUAGE sql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
SELECT item.$(ident ord)::integer AS $(ident ord),
       item.$(ident ip) AS $(ident ip),
       $(pg_ident find_geoname_id_by_ip)(item.$(ident ip)) AS $(ident geoname_id)
FROM jsonb_array_elements_text(p_ips) WITH ORDINALITY AS item($(ident ip), $(ident ord))
ORDER BY item.$(ident ord);
\$\$;

SQL
  return_cols="$(pg_ident ord) integer, $(pg_ident geoname_id) integer"
  for ((i = 0; i < ${#routine_names[@]}; i++)); do
    return_cols="${return_cols}, $(pg_ident "${routine_names[i]}") ${routine_types[i]}"
  done
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_geoname_ids_json)(jsonb);

CREATE OR REPLACE FUNCTION $(pg_ident find_geoinfo_by_geoname_ids_json)(p_geoname_ids jsonb)
RETURNS TABLE($return_cols)
LANGUAGE sql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
WITH input AS (
    SELECT item.$(ident ord)::integer AS $(ident ord),
           item.$(ident geoname_id)::integer AS $(ident geoname_id)
    FROM jsonb_array_elements_text(p_geoname_ids) WITH ORDINALITY AS item($(ident geoname_id), $(ident ord))
)
SQL
  write_pg_batch_geoinfo_select_columns "$file" false routine_names routine_exprs
  write_geoname_lookup_from_input_sql "$file" "" "i.$(ident geoname_id)"
  cat >> "$file" <<SQL
ORDER BY i.$(ident ord);
\$\$;

SQL
  return_cols="$(pg_ident ord) integer, $(pg_ident ip) text, $(pg_ident geoname_id) integer"
  for ((i = 0; i < ${#routine_names[@]}; i++)); do
    return_cols="${return_cols}, $(pg_ident "${routine_names[i]}") ${routine_types[i]}"
  done
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_ips_json)(jsonb);

CREATE OR REPLACE FUNCTION $(pg_ident find_geoinfo_by_ips_json)(p_ips jsonb)
RETURNS TABLE($return_cols)
LANGUAGE sql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
WITH input AS (
    SELECT item.$(ident ord)::integer AS $(ident ord),
           item.$(ident ip) AS $(ident ip),
           $(pg_ident find_geoname_id_by_ip)(item.$(ident ip)) AS $(ident geoname_id)
    FROM jsonb_array_elements_text(p_ips) WITH ORDINALITY AS item($(ident ip), $(ident ord))
)
SQL
  write_pg_batch_geoinfo_select_columns "$file" true routine_names routine_exprs
  write_geoname_lookup_from_input_sql "$file" "" "i.$(ident geoname_id)"
  cat >> "$file" <<SQL
ORDER BY i.$(ident ord);
\$\$;

SQL
  mix_expr="$(build_location_mix_expr emoji)"
  iso_expr="$(build_location_mix_expr iso)"
  if [[ -n "$mix_expr" ]]; then
    mix_select="$(pg_ident build_location_mix)(i.$(pg_ident geoname_id), append_emoji)"
  else
    mix_select="NULL::text"
  fi
  if [[ -n "$iso_expr" ]]; then
    iso_select="$(pg_ident build_location_mix_with_iso_code)(i.$(pg_ident geoname_id))"
  else
    iso_select="NULL::text"
  fi
  cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident build_location_mixes_by_geoname_ids_json)(jsonb, integer);

CREATE OR REPLACE FUNCTION $(pg_ident build_location_mixes_by_geoname_ids_json)(p_geoname_ids jsonb, append_emoji integer)
RETURNS TABLE($(pg_ident ord) integer, $(pg_ident geoname_id) integer, $(pg_ident location_mix) text, $(pg_ident location_mix_iso) text)
LANGUAGE sql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
WITH input AS (
    SELECT item.$(ident ord)::integer AS $(ident ord),
           item.$(ident geoname_id)::integer AS $(ident geoname_id)
    FROM jsonb_array_elements_text(p_geoname_ids) WITH ORDINALITY AS item($(ident geoname_id), $(ident ord))
)
SELECT i.$(ident ord),
       i.$(ident geoname_id),
       $mix_select AS $(ident location_mix),
       $iso_select AS $(ident location_mix_iso)
FROM input i
ORDER BY i.$(ident ord);
\$\$;

SQL
}

write_99_routines() {
  local file="$RUN_DIR/99_routines.sql"
  local definer="" has4=false has6=false locale return_cols routine_names routine_exprs routine_types i
  array_contains "4" "${IP_VERSIONS[@]}" && has4=true
  array_contains "6" "${IP_VERSIONS[@]}" && has6=true
  start_sql_file "$file" "IP lookup helper functions and procedures"
  if ! is_location_family; then
    if [[ "$DBMS" == "mysql" ]]; then
      [[ -n "$MYSQL_ROUTINE_DEFINER" ]] && definer="DEFINER=$MYSQL_ROUTINE_DEFINER "
      if [[ "$has6" == "true" ]]; then
        write_mysql_inet6_function "$file"
      fi
      cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(mysql_ident find_geoname_id_by_ip);
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoinfo_by_ip);
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoname_ids_by_ips_json);
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoinfo_by_ips_json);
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoinfo_by_geoname_ids_json);
DROP PROCEDURE IF EXISTS $(mysql_ident build_location_mixes_by_geoname_ids_json);
DROP FUNCTION IF EXISTS $(mysql_ident build_location_mix);
DROP FUNCTION IF EXISTS $(mysql_ident build_location_mix_with_iso_code);

SQL
      write_mysql_network_lookup_procedure "$file" "$definer" "$has4" "$has6"
      write_mysql_network_lookup_batch_procedure "$file" "$definer" "$has4" "$has6"
    else
      cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident find_geoname_id_by_ip)(text);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_ip)(text);
DROP FUNCTION IF EXISTS $(pg_ident find_geoname_ids_by_ips_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_ips_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_geoname_ids_json)(jsonb);
DROP FUNCTION IF EXISTS $(pg_ident build_location_mixes_by_geoname_ids_json)(jsonb, integer);
DROP FUNCTION IF EXISTS $(pg_ident build_location_mix)(integer, integer);
DROP FUNCTION IF EXISTS $(pg_ident build_location_mix_with_iso_code)(integer);

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
    if [[ "$has6" == "true" ]]; then
      write_mysql_inet6_function "$file"
    fi
    write_mysql_network_lookup_procedure "$file" "$definer" "$has4" "$has6"
    write_mysql_network_lookup_batch_procedure "$file" "$definer" "$has4" "$has6"
    cat >> "$file" <<SQL
DELIMITER \$\$
DROP FUNCTION IF EXISTS $(mysql_ident find_geoname_id_by_ip)\$\$
CREATE ${definer}FUNCTION $(mysql_ident find_geoname_id_by_ip)(ip VARCHAR(45)) RETURNS INT UNSIGNED
    READS SQL DATA
    DETERMINISTIC
BEGIN
    DECLARE result INT UNSIGNED DEFAULT NULL;
SQL
    [[ "$has6" == "true" ]] && echo "    DECLARE ip6 DECIMAL(39,0) DEFAULT NULL;" >> "$file"
    [[ "$has4" == "true" ]] && echo "    DECLARE ip4 INT UNSIGNED DEFAULT NULL;" >> "$file"
    if [[ "$has6" == "true" ]]; then
      cat >> "$file" <<SQL
    IF INSTR(ip, ':') > 0 THEN
        SET ip6 = $(mysql_ident inet6_aton_decimal)(ip);
        IF ip6 IS NULL THEN RETURN NULL; END IF;
        SELECT candidate.$(mysql_ident v_geoname_id) INTO result
        FROM (SELECT $(mysql_ident v_geoname_id), $(mysql_ident last_ip) FROM $(mysql_ident ipv6) WHERE $(mysql_ident start_ip) <= ip6 ORDER BY $(mysql_ident start_ip) DESC LIMIT 1) AS candidate
        WHERE candidate.$(mysql_ident last_ip) >= ip6;
        RETURN result;
    END IF;
SQL
    fi
    if [[ "$has4" == "true" ]]; then
      cat >> "$file" <<SQL
    SET ip4 = INET_ATON(ip);
    IF ip4 IS NULL THEN RETURN NULL; END IF;
    SELECT candidate.$(mysql_ident v_geoname_id) INTO result
    FROM (SELECT $(mysql_ident v_geoname_id), $(mysql_ident last_ip) FROM $(mysql_ident ipv4) WHERE $(mysql_ident start_ip) <= ip4 ORDER BY $(mysql_ident start_ip) DESC LIMIT 1) AS candidate
    WHERE candidate.$(mysql_ident last_ip) >= ip4;
    RETURN result;
SQL
    else
      echo "    RETURN NULL;" >> "$file"
    fi
    echo "END\$\$" >> "$file"
    echo >> "$file"
    routine_select_parts routine_names routine_exprs routine_types
    if [[ "${#routine_names[@]}" -eq 0 ]]; then
      cat >> "$file" <<SQL
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoinfo_by_ip)\$\$

-- find_geoinfo_by_ip was not generated because no configured output columns can be returned.
SQL
    else
      cat >> "$file" <<SQL
DROP PROCEDURE IF EXISTS $(mysql_ident find_geoinfo_by_ip)\$\$
CREATE ${definer}PROCEDURE $(mysql_ident find_geoinfo_by_ip)(ip VARCHAR(45))
    READS SQL DATA
BEGIN
    SELECT
SQL
      for ((i = 0; i < ${#routine_names[@]}; i++)); do
        if (( i == 0 )); then
          printf "        %s AS %s\n" "${routine_exprs[i]}" "$(mysql_ident "${routine_names[i]}")" >> "$file"
        else
          printf "        , %s AS %s\n" "${routine_exprs[i]}" "$(mysql_ident "${routine_names[i]}")" >> "$file"
        fi
      done
      if is_city_location; then
        write_geoname_lookup_from_sql "$file" "    "
        cat >> "$file" <<SQL
    WHERE ci.$(mysql_ident geoname_id) = $(mysql_ident find_geoname_id_by_ip)(ip);
END\$\$
SQL
      else
        write_geoname_lookup_from_sql "$file" "    "
        cat >> "$file" <<SQL
    WHERE c.$(mysql_ident geoname_id) = $(mysql_ident find_geoname_id_by_ip)(ip);
END\$\$
SQL
      fi
    fi
    write_mysql_build_location_functions "$file" "$definer"
    write_mysql_location_batch_procedures "$file" "$definer"
    echo "DELIMITER ;" >> "$file"
  else
    write_pg_network_lookup_function "$file" "$has4" "$has6"
    write_pg_network_lookup_family_functions "$file" "$has4" "$has6"
    write_pg_network_lookup_batch_function "$file" "$has4" "$has6"
    write_pg_network_lookup_batch_family_functions "$file" "$has4" "$has6"
    cat >> "$file" <<SQL
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
    v_ip := p_ip::inet;
SQL
    if [[ "$has4" == "true" ]]; then
      cat >> "$file" <<SQL
    IF family(v_ip) = 4 THEN
        SELECT candidate.$(pg_ident v_geoname_id) INTO result
        FROM (SELECT $(pg_ident v_geoname_id), $(pg_ident last_ip) FROM $(pg_ident ipv4) WHERE $(pg_ident start_ip) <= v_ip ORDER BY $(pg_ident start_ip) DESC LIMIT 1) AS candidate
        WHERE candidate.$(pg_ident last_ip) >= v_ip;
        RETURN result;
    END IF;
SQL
    fi
    if [[ "$has6" == "true" ]]; then
      cat >> "$file" <<SQL
    IF family(v_ip) = 6 THEN
        SELECT candidate.$(pg_ident v_geoname_id) INTO result
        FROM (SELECT $(pg_ident v_geoname_id), $(pg_ident last_ip) FROM $(pg_ident ipv6) WHERE $(pg_ident start_ip) <= v_ip ORDER BY $(pg_ident start_ip) DESC LIMIT 1) AS candidate
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
    routine_select_parts routine_names routine_exprs routine_types
    if [[ "${#routine_names[@]}" -eq 0 ]]; then
      cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_ip)(text);

-- find_geoinfo_by_ip was not generated because no configured output columns can be returned.
SQL
    else
      return_cols=""
      for ((i = 0; i < ${#routine_names[@]}; i++)); do
        return_cols="${return_cols}${return_cols:+, }$(pg_ident "${routine_names[i]}") ${routine_types[i]}"
      done
      cat >> "$file" <<SQL
DROP FUNCTION IF EXISTS $(pg_ident find_geoinfo_by_ip)(text);

CREATE OR REPLACE FUNCTION $(pg_ident find_geoinfo_by_ip)(p_ip text)
RETURNS TABLE($return_cols)
LANGUAGE sql
STABLE
$(pg_routine_search_path_clause)
AS \$\$
SELECT
SQL
      for ((i = 0; i < ${#routine_names[@]}; i++)); do
        if (( i == 0 )); then
          printf "    %s AS %s\n" "${routine_exprs[i]}" "$(pg_ident "${routine_names[i]}")" >> "$file"
        else
          printf "    , %s AS %s\n" "${routine_exprs[i]}" "$(pg_ident "${routine_names[i]}")" >> "$file"
        fi
      done
      if is_city_location; then
        write_geoname_lookup_from_sql "$file" ""
        cat >> "$file" <<SQL
WHERE ci.$(pg_ident geoname_id) = $(pg_ident find_geoname_id_by_ip)(p_ip);
\$\$;
SQL
      else
        write_geoname_lookup_from_sql "$file" ""
        cat >> "$file" <<SQL
WHERE c.$(pg_ident geoname_id) = $(pg_ident find_geoname_id_by_ip)(p_ip);
\$\$;
SQL
      fi
    fi
    write_pg_build_location_functions "$file"
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
SOURCE 98_promote.sql
SOURCE 99_routines.sql
SOURCE 100_cleanup_raw.sql
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

cd "$(cd -- "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)" || exit
SH
  if [[ "$DBMS" == "mysql" ]]; then
    cat >> "$file" <<SH
MYSQL_HOST="$MYSQL_HOST"
MYSQL_PORT="$MYSQL_PORT"
MYSQL_USER="$MYSQL_USER"
export MYSQL_PWD="\${MYSQL_PWD:-$MYSQL_PASSWORD}"
START_SECONDS="\$(date +%s)"
info "Importing..."
set +e
$MYSQL_COMMAND --local-infile=1 --host="\$MYSQL_HOST" --port="\$MYSQL_PORT" --user="\$MYSQL_USER" $MYSQL_EXTRA_ARGS < load_data.sql
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
    cat >> "$file" <<SH
PGHOST="$POSTGRESQL_HOST"
PGPORT="$POSTGRESQL_PORT"
PGUSER="$POSTGRESQL_USER"
PGDATABASE="$POSTGRESQL_DATABASE"
export PGPASSWORD="\${PGPASSWORD:-$POSTGRESQL_PASSWORD}"
START_SECONDS="\$(date +%s)"
info "Importing..."
set +e
$POSTGRESQL_COMMAND --host="\$PGHOST" --port="\$PGPORT" --username="\$PGUSER" --dbname="\$PGDATABASE" -v ON_ERROR_STOP=1 $POSTGRESQL_EXTRA_ARGS -f load_data.sql
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
