# MaxMind CSV to SQL

Single Bash entrypoint for generating MySQL 8 or PostgreSQL import packages from
MaxMind GeoIP/GeoIP2/GeoLite2 CSV ZIP archives.

Current release config format: `v1.3`

Supported config set includes:

* location databases: GeoLite2 City/Country, GeoIP2 City/Country, GeoIP2 Enterprise
* network-only databases: Anonymous IP, Anonymous Plus, Residential Proxy, ISP,
  Connection Type, Domain, ASN, IP Risk, Static IP Score, and User Count

## Requirements

* Bash 5+
* `awk`
* `unzip`
* `curl` for HTTP(S) downloads
* `mysql` or `psql` only when `settings.auto_execute_loader_sh = true`, or when running the generated `loader.sh`

On Windows, run the scripts from a Unix-like shell such as MSYS2 `MINGW64` or `UCRT64`.

For HTTP(S) sources, cached downloads in `converted/_archives/` are reused when
a `HEAD` request returns a `Content-Length` equal to the cached ZIP size.

## Usage

```bash
./maxmind-csv2sql-converter.sh -c configs/default.mysql.ini
./maxmind-csv2sql-converter.sh -c configs/default.postgresql.ini
./maxmind-csv2sql-converter.sh -c configs/default.mysql.ini --list-editions
./maxmind-csv2sql-converter.sh -c configs/default.postgresql.ini --list-editions
```

The `convert-*.sh` scripts are thin wrappers for the default configs:

```bash
./convert-default.mysql.sh
./convert-default.postgresql.sh
```

Config filenames are significant:

```text
project_name.database_type.ini
```

Examples:

```text
default.mysql.ini
default.postgresql.ini
production.mysql.ini
production.postgresql.ini
```

The default configs keep all supported editions in one file per database type:
`configs/default.mysql.ini` and `configs/default.postgresql.ini`. A normal run
converts every uncommented edition from `[editions].edition_ids`;
`--list-editions` prints the effective list.

Config lookup first checks an edition-scoped section such as
`[GeoLite2-Country-CSV.download]`, then falls back to an unscoped section such as
`[download]`. Package-level execution, output, cleanup, archive, and client
settings live in `[settings]` because one config generates one output package
and one `loader.sh`; the database type comes from the config filename suffix,
such as `.mysql.ini` or `.postgresql.ini`. `[settings]` keys are read only from
that exact section, not from edition-scoped sections.
Single-edition configs can still use plain `[download]`, `[database]`,
`[convert]`, and `[columns.<table>]` sections.

Example MySQL package settings:

```ini
[settings]
# MySQL client command; values: command name from PATH or path to executable.
mysql_command = mysql
# mysql_command = C:/Program Files/MySQL/MySQL Server 8.0/bin/mysql.exe
# MySQL host; values: IP address, DNS name, or localhost.
mysql_host = 127.0.0.1
# MySQL port; values: integer, usually 3306.
mysql_port = 3306
# MySQL user; values: user name.
mysql_user = root
# MySQL password; values: string or empty for passwordless authentication.
mysql_password = root
# Additional mysql arguments; values: CLI argument string or empty.
mysql_extra_args =
# DEFINER for MySQL routines; values: user@host in MySQL syntax or empty to omit DEFINER.
mysql_routine_definer =
# Base output directory; values: relative or absolute path.
output_dir = ../converted
# Generated result ZIP name; values: filename with or without .zip, or empty to skip archive creation.
output_archive_name =
# Execute the generated SQL after preparing files; values: true or false.
auto_execute_loader_sh = false
# Delete extracted CSV/TSV files after successful auto_execute_loader_sh=true run; values: true or false.
auto_delete_csvs = false
# Print converter debug timings; values: true or false.
on_debug = false
```

Example PostgreSQL package settings:

```ini
[settings]
# PostgreSQL client command; values: command name from PATH or path to executable.
postgresql_command = psql
# postgresql_command = C:/Program Files/PostgreSQL/16/bin/psql.exe
# PostgreSQL host; values: IP address, DNS name, or localhost.
postgresql_host = 127.0.0.1
# PostgreSQL port; values: integer, usually 5432.
postgresql_port = 5432
# PostgreSQL user; values: user name.
postgresql_user = postgres
# PostgreSQL database used for the connection; values: existing database name.
postgresql_database = maxmind
# PostgreSQL password; values: string or empty for passwordless/.pgpass authentication.
postgresql_password = postgres
# Additional psql arguments; values: CLI argument string or empty.
postgresql_extra_args =
# Base output directory; values: relative or absolute path.
output_dir = ../converted
# Generated result ZIP name; values: filename with or without .zip, or empty to skip archive creation.
output_archive_name =
# Execute the generated SQL after preparing files; values: true or false.
auto_execute_loader_sh = false
# Delete extracted CSV/TSV files after successful auto_execute_loader_sh=true run; values: true or false.
auto_delete_csvs = false
# Print converter debug timings; values: true or false.
on_debug = false
```

`postgresql_database` is the existing database passed to `psql --dbname`.
Generated SQL creates schemas inside that database; it does not run
`CREATE DATABASE` or switch databases. Per-edition `schema_name` controls the
target MySQL database name or PostgreSQL schema name for generated tables.

For one-off debug timing without editing the config, set `ON_DEBUG=true` in the
environment before running the converter. Debug timing prints each measured step and
its elapsed time to stderr.

Edition-level conversion settings, including custom SQL generator selection,
belong in `[<edition>.convert]`:

```ini
[GeoLite2-Country-CSV.convert]
# SQL Bash generator file; values: functions.bash or relative/absolute path to a custom functions.bash.
sql_bash_generator_file = functions.bash
# IP block versions to import; values: 4, 6, or comma-separated list 4,6.
ip_versions = 4,6
# Locations CSV locales to import; values: en, ru, de, es, fr, ja, pt-BR, zh-CN, comma-separated.
locales = en,ru,de,es,fr,ja,pt-BR,zh-CN
# Blocks CSV columns used, in priority order, to derive e_geoname_id; values: geoname_id, registered_country_geoname_id, represented_country_geoname_id.
e_geoname_id_priority_columns = geoname_id,registered_country_geoname_id,represented_country_geoname_id
```

With the default `functions.bash` value, the converter first resolves
`../generators/<project_name>/functions.bash` relative to the config directory.
For configs under `configs/`, that maps to `generators/<project_name>/functions.bash`
in the repository root. If it is missing, the converter falls back to the bundled
`generators/default/functions.bash`.

Each processed MaxMind edition is validated against the root directory inside
the ZIP, for example `GeoLite2-Country-CSV_Example/` or `GeoLite2-City-CSV_20260605/`.

## Download Sources

Each edition has its own archive source:

```ini
[editions]
# MaxMind editions to process sequentially; values: GeoIP/GeoIP2/GeoLite2 *-CSV ids, one per line or comma-separated.
# Comment out editions that should not be converted.
edition_ids =
  GeoIP2-Anonymous-IP-CSV
  GeoIP-Anonymous-Plus-CSV
  GeoLite2-ASN-CSV
#  GeoIP2-City-CSV
  GeoLite2-City-CSV
  GeoIP2-Connection-Type-CSV
#  GeoIP2-Country-CSV
  GeoLite2-Country-CSV
  GeoIP2-Domain-CSV
  GeoIP2-Enterprise-CSV
  GeoIP2-IP-Risk-CSV
  GeoIP2-ISP-CSV
  GeoIP-Residential-Proxy-CSV
  GeoIP2-Static-IP-Score-CSV
  GeoIP2-User-Count-CSV

[GeoLite2-Country-CSV.download]
# MaxMind edition expected by this section; values: one edition_id from [editions].
edition_id = GeoLite2-Country-CSV
# MaxMind license key for official downloads; values: a string, or empty for local archives and URLs without ${license_key}.
license_key = M8jFjv3vZWrOCaZN
# MaxMind ZIP archive source; values: HTTP(S) URL or local path; supports ${edition_id}, ${license_key}, ${database_type}, and ${project_name}.
source_archive_uri = https://download.maxmind.com/app/geoip_download?edition_id=${edition_id}&license_key=${license_key}&suffix=zip
# Mirror examples:
# source_archive_uri = https://some.maxmind.csv.repository/${edition_id}.zip
# source_archive_uri = ../test/data/GeoLite2-Country-CSV_20260605.zip
# Try a direct download before proxy attempts; values: true or false.
try_without_proxy = true
# curl connection timeout in seconds; values: integer greater than 0.
connect_timeout_seconds = 5
# Maximum time for one curl download attempt in seconds; values: integer greater than 0.
max_time_seconds = 1800
# Number of curl retry attempts; values: integer 0 or greater.
retries = 2
# Proxy list file; values: relative/absolute path or empty when proxies are not needed.
proxy_file = proxy.txt
...
```

Mirror and local archive examples:

```ini
# Mirror examples:
# source_archive_uri = https://some.maxmind.csv.repository/${edition_id}.zip
# source_archive_uri = ../test/data/GeoLite2-Country-CSV_Example.zip
# source_archive_uri = C:\data\GeoLite2-Country-CSV_20260605.zip
```

Template variables available in `source_archive_uri`: `${edition_id}`, `${license_key}`, `${database_type}`, and `${project_name}`.

## Workflow

The script extracts selected CSV files, generates raw import tables, imports CSV
into those raw tables, builds staging tables, creates indexes/routines, and
promotes staging tables to production names.

Output is written to:

```text
converted/<project_name>.<database_type>/
```

For `default.mysql.ini` this is `converted/default.mysql/`; for
`default.postgresql.ini` this is `converted/default.postgresql/`. When multiple
editions are enabled, generated SQL files are accumulated in that one
project/database directory. Extracted CSV/TSV files are stored per archive root under
`converted/<project_name>.<database_type>/csv/`, for example
`converted/default.mysql/csv/GeoLite2-Country-CSV_Example/`, to avoid
filename collisions between editions and between MySQL/PostgreSQL runs.

Important generated files:

* `00_create_raw.sql`, `10_load_raw.sql`, `20_transform_stage.sql`,
  `90_indexes_stage.sql`, `98_promote.sql`, `99_routines.sql`,
  `100_cleanup_raw.sql`.
* `load_data.sql` - full import script.
* `loader.sh` - runs `load_data.sql` with `mysql` or `psql`.

The actual include order is defined by `load_data.sql`. MySQL runs cleanup
before promotion and then creates routines; PostgreSQL promotes, creates
routines, and cleans raw tables inside its single transaction. See
`generators/readme.md` when implementing a custom SQL Bash generator.

With `settings.auto_execute_loader_sh = false`, the package is generated but not
run. With `settings.auto_execute_loader_sh = true`, `loader.sh` is executed
immediately.

## Transactions

PostgreSQL `load_data.sql` wraps schema creation, raw load, transform, indexing,
promote, routines, and cleanup in one `BEGIN`/`COMMIT`.

MySQL cannot honestly wrap the same whole flow because statements such as
`CREATE SCHEMA`, `CREATE/DROP/ALTER TABLE`, `CREATE/DROP FUNCTION/PROCEDURE`,
and `RENAME TABLE` perform implicit commits. Generated MySQL SQL wraps
`LOAD DATA` and `INSERT` batches in explicit transactions where possible, while
DDL and promote remain implicit-commit operations. Promote starts with one
multi-table `RENAME TABLE`, then normalizes generated MySQL secondary index and
foreign-key names.

## Output Shape

Every database creates `dataset_metadata` plus IP block tables for the enabled
IP versions. Location databases additionally create normalized location
tables. City and Enterprise configs create `timezone`,
`country`, `subdivision1`, `subdivision2`, `city`, and `ipv4` and/or `ipv6`.
Enterprise also creates `isp` and adds foreign keys from enabled
`ipv4/ipv6.isp_id` columns to `isp.isp_id`.

Country configs create `country` plus `ipv4` and/or `ipv6`.

Foreign keys from a network to its four Location references use
`ON UPDATE RESTRICT ON DELETE RESTRICT`. A Location row is shared lookup data:
deleting a represented- or registered-country row must not silently delete the
whole network row through `CASCADE`. The normalized City hierarchy keeps
`CASCADE`, where deleting a parent dimension intentionally removes its child
dimension rows. Normal imports replace staged tables atomically and do not
depend on either action.

Network-only databases create only `ipv4` and/or `ipv6` for the enabled IP
versions. The `network` column is the natural primary key; generated
`start_ip`/`last_ip` columns support range lookup/indexing. In MySQL these range
columns are numeric values, while in PostgreSQL they are `inet` values.
PostgreSQL `inet` always has a prefix length; generated range boundaries use
host prefixes (`/32` for IPv4 and `/128` for IPv6), not the source network
prefix. These datasets do not have synthetic foreign keys because MaxMind
provides no separate stable key beyond `network`.

## Output Columns

Project configs can choose output columns via `[columns.<table>]` or
`[<edition>.columns.<table>]` sections.
`name = true` and `continent_name = true` create one column per locale from
`convert.locales`, such as `name_en` and `name_ru`.

Some columns are required by the default generator:

* all datasets: metadata fields plus IP `network` and range columns
* location datasets: primary keys, `e_geoname_id`, and
  `e_geoname_source_code`; the three source GeoName ID columns are optional
* Enterprise: `isp.isp_id` when the `isp` table is enabled

Required columns are intentionally omitted from the bundled configs; missing
settings use the default enabled value. Optional dimension tables that would
contain only their required key are not generated. For example, setting
`[GeoLite2-City-CSV.columns.timezone] name = false` omits the `timezone` table
and the dependent `city.time_zone_id` column.

Raw tables are created from actual CSV headers. Newly added MaxMind columns are
imported into raw tables automatically; production output must be enabled in the
config and typed in the default generator.

## Location Filters

Location-capable editions can restrict imported location rows with
`[<edition>.location_filters]`, or plain `[location_filters]` in a single-edition
config. These sections apply only to City, Country, and Enterprise archives.
Network-only archives have no Locations CSV, so no location filters are read.

Filter keys must be real columns from the archive's `*-Locations-en.csv`.
Values are case-insensitive regular expressions. A comma-separated value creates
an OR group for one column, and multiple filter keys are combined with AND.
If a regex itself contains a comma, wrap that value in double quotes.

Country, City, and Enterprise archives can filter by common location columns
such as `geoname_id`, `continent_code`, `continent_name`, `country_iso_code`,
`country_name`, and `is_in_european_union`. City and Enterprise archives can
also filter by city-level columns such as
`subdivision_1_iso_code`, `subdivision_1_name`, `subdivision_2_iso_code`,
`subdivision_2_name`, `city_name`, `metro_code`, and `time_zone`.

Example:

```ini
[GeoLite2-City-CSV.location_filters]
# Optional Locations CSV row filters for this edition; all enabled keys are combined with AND.
# Values: case-insensitive regex or comma-separated regex list; quote values that contain commas.
# Uncomment only the filters you need.
# Filter by geoname_id; values: regex or comma-separated regex list.
# geoname_id = .*777.*
# Filter by continent_code; values: regex or comma-separated regex list.
# continent_code = EU,NA,OC
# Filter by continent_name; values: regex or comma-separated regex list.
# continent_name = Europe|Africa,Asia
# Filter by country_iso_code; values: regex or comma-separated regex list.
# country_iso_code = AU,NZ,GB,IE,US,CA,CY
# Filter by country_name; values: regex or comma-separated regex list.
# country_name = Austr.*,Zealand$,^United,Ireland,Canada|Cyprus
# Filter by is_in_european_union; values: regex, usually 0 or 1.
# is_in_european_union = 0|1
# Filter by subdivision_1_iso_code; values: regex or comma-separated regex list.
# subdivision_1_iso_code = WO|JD|NU|GE|A.*
# Filter by subdivision_1_name; values: regex or comma-separated regex list.
# subdivision_1_name = .*O.*
# Filter by subdivision_2_iso_code; values: regex or comma-separated regex list.
# subdivision_2_iso_code = .*
# Filter by subdivision_2_name; values: regex or comma-separated regex list.
# subdivision_2_name = .*A.*
# Filter by city_name; values: regex or comma-separated regex list; quote values that contain commas.
# city_name = Newport,^Clinton$|^Richmond$,"Mandria, Paphos",^Salem
# Filter by metro_code; values: regex or comma-separated regex list.
# metro_code = .*
# Filter by time_zone; values: regex or comma-separated regex list.
# time_zone = .*/.*E.*
```

## Lookup Helpers

The default generator exposes the same logical API in MySQL and PostgreSQL.
MySQL table-valued entry points are procedures called with `CALL`; PostgreSQL
entry points are functions queried with `SELECT * FROM`. Scalar helpers are
functions in both databases.

### Network lookup in every dataset

Every generated namespace, including ASN and all other network-only editions,
contains:

* `find_network_by_ip(ip)`
* `find_networks_by_json_ips(ips_json, page, per_page)`
* `get_dataset_metadata()`

Network lookup always uses one stable result shape: `status`, `ip`,
`ip_version`, followed by the union of the configured IPv4/IPv6 output
columns. A single lookup always returns exactly one row. Status is `ok` for a
matching network, `not_found` for a valid address outside the dataset, and
`invalid_ip` for invalid input. CIDR input such as `192.0.2.0/24` is not
accepted as an IP address.

The JSON batch helper requires a top-level array and accepts 1-based `page` and
positive `per_page` arguments. It preserves order and duplicates; `ord` is the
absolute 1-based position in the original array. Every returned row also has
`total_count`, the number of input elements before pagination, so a client can
calculate `ceil(total_count / per_page)`. Strings are validated strictly; JSON
`null`, objects, arrays, and invalid address strings produce an `invalid_ip`
row without aborting the rest of the page.

The stable union shape is intentional for mixed IPv4/IPv6 requests. For
example, GeoIP2 User Count returns all configured IPv4 and IPv6 count columns
from `find_networks_by_json_ips`; columns that do not apply to the matched IP
family are null. The physical `ipv4` and `ipv6` tables still contain only the
columns enabled for that family.

PostgreSQL additionally provides IP-family-specific helpers when that family
is enabled:

* `find_ipv4_network_by_ip(ip)` and `find_ipv6_network_by_ip(ip)`
* `find_ipv4_networks_by_json_ips(ips_json, page, per_page)` and
  `find_ipv6_networks_by_json_ips(ips_json, page, per_page)`

Examples:

```sql
-- MySQL
CALL maxmind_asn.find_network_by_ip('1.0.0.1');
CALL maxmind_asn.find_networks_by_json_ips(
    JSON_ARRAY('1.0.0.1', '203.0.113.1', 'bad', NULL), 1, 40
);

-- PostgreSQL
SELECT * FROM maxmind_asn.find_network_by_ip('1.0.0.1');
SELECT * FROM maxmind_asn.find_networks_by_json_ips(
    '["1.0.0.1", "203.0.113.1", "bad", null]'::jsonb, 1, 40
);
```

### Effective GeoName IDs

MaxMind's `geoname_id` is nullable. It is not interchangeable with
`registered_country_geoname_id` or `represented_country_geoname_id`; each
column describes a different role. Location network tables always add:

* `e_geoname_id` — the effective location selected by the configured priority;
* `e_geoname_source_code` — the exact source column used for that row.

Each source role is stored only when its `columns.ipv4`/`columns.ipv6` setting
is enabled. Effective values are still calculated from the raw Blocks CSV, so
all three source columns may be disabled without losing `e_geoname_id`.

The source codes have fixed meanings independent of configured priority:

| Code | Source column |
| ---: | --- |
| `1` | `geoname_id` |
| `2` | `registered_country_geoname_id` |
| `3` | `represented_country_geoname_id` |

The converter stores the value and source together. The `CHECK` constraint
enforces their nullability and valid source codes; when a source role is also
stored, it additionally enforces equality with `e_geoname_id`. It does not
infer the source by comparing values, because two source columns can contain
the same GeoName ID.
When no configured source resolves to a loaded Location row, both effective
columns are null and the network row is still retained. Generic network lookup
has `status = 'ok'` because the network was found; the ID-focused location API
uses `status = 'no_location'`. Enabled original IDs are returned as stored,
and network flags and other edition-specific data remain available. For
example, MaxMind's all-null-ID example rows carry anonymous-proxy, satellite,
or anycast flags and must not be confused with a network absent from the data.

Selection is intentionally two-pass. In configured priority order, the
converter first chooses a source that resolves to a loaded Location row with a
country ISO code; if none does, it chooses the first source that resolves to
any loaded Location row. This preserves useful country-level output when a
more specific source cannot supply it. `schema_version` identifies this
algorithm, while metadata preserves the configured source order.

Location schemas provide these ID-focused helpers:

* `find_geoname_id_by_ip(ip)` returns the original MaxMind `geoname_id` only
  and is generated only when that column is enabled for at least one selected
  IP family;
* `find_e_geoname_id_by_ip(ip)` returns `e_geoname_id`;
* `find_geoname_ids_by_ip(ip)` returns the status, network, effective ID,
  readable effective source, and the enabled original IDs;
* `find_geoname_ids_by_json_ips(ips_json, page, per_page)` is the safe paged
  batch form and includes `total_count`.

The two `find_geoname_ids...` entry points use `ok`, `no_location`,
`not_found`, and `invalid_ip`. `no_location` means that the IP matched a stored
network but no configured source resolved to a loaded Location row. Their
public result uses `e_geoname_id` and `e_geoname_source`; a
column named `geoname_id` in these ID-focused results means the original
MaxMind field. Result signatures contain the union of roles enabled for IPv4
and IPv6. A role that is enabled only for the other family is returned as
`NULL`.

```sql
-- MySQL
CALL maxmind_geoip2_city.find_geoname_ids_by_ip('81.2.69.142');
CALL maxmind_geoip2_city.find_geoname_ids_by_json_ips(
    JSON_ARRAY('81.2.69.142', 'bad', NULL, '2001:218::'), 1, 40
);

-- PostgreSQL
SELECT *
FROM maxmind_geoip2_city.find_geoname_ids_by_ip('81.2.69.142');
SELECT *
FROM maxmind_geoip2_city.find_geoname_ids_by_json_ips(
    '["81.2.69.142", "bad", null, "2001:218::"]'::jsonb, 1, 40
);
```

### Location data and labels

City, Country, and Enterprise schemas also generate:

* `find_e_geoname_ids_by_json_ips(ips_json, page, per_page)`
* `find_geoinfo_by_json_ips(ips_json, include_continent, include_iso_code,
  include_emoji, page, per_page)`
* `find_geoinfo_by_json_geoname_ids(geoname_ids_json, include_continent,
  include_iso_code, include_emoji, page, per_page)`
* `build_location_label_by_geoname_id(geoname_id, locale, include_continent,
  include_iso_code, include_emoji)`
* `build_location_labels_by_ip(ip, locales_json, include_continent,
  include_iso_code, include_emoji)`
* `build_location_labels_by_json_geoname_ids(geoname_ids_json, locale,
  include_continent, include_iso_code, include_emoji, page, per_page)`

The three include arguments use `0` or `1`.
The two `find_geoinfo...` routines return `country_iso_code` when that source
column is enabled and one `location_<locale>` column per configured locale.
Their include arguments apply to every `location_<locale>` value. They do not
return a separate `location_label`; use a `build_location_*` helper when one
label for a selected locale is needed.

The public ID columns of these batch routines are:

| Routine | ID columns | Meaning |
| --- | --- | --- |
| `find_e_geoname_ids_by_json_ips` | `ip`, `e_geoname_id` | Effective ID selected from the configured source priority |
| `find_geoinfo_by_json_ips` | `ip`, `geoname_id` | Location lookup key resolved from the matching network's `e_geoname_id` |
| `find_geoinfo_by_json_geoname_ids` | `geoname_id` | Location lookup key supplied in the input JSON array |

Thus, `geoname_id` in a geoinfo result is the Location lookup key used to build
`country_iso_code` and `location_<locale>` values. If no Location row matches,
the key is retained and the derived values are null. Use
`find_e_geoname_ids_by_json_ips` when the public result must explicitly retain
the effective-ID name `e_geoname_id`.

`build_location_label_by_geoname_id` prefers the requested configured locale,
then English when available, then the remaining configured locales. Fallback
is applied independently to each hierarchy component, so a missing Russian
city name can fall back to English without changing an available Russian
country or subdivision name. Duplicate country/subdivision/city names are
suppressed. Locale values are normalized (`_` to `-`, case-insensitive), and
both `ru` and an accidentally JSON-encoded `"ru"` are accepted.

`build_location_labels_by_ip` performs one network lookup, then returns one row
per requested locale. It always returns the effective ID/source and
`e_geoname_label`. Every enabled original role is followed by its own resolved
label: `geoname_label`, `registered_country_label`, or
`represented_country_label`. Disabled roles are omitted from the result. This
is a normal many-to-one lookup: any number of network rows may refer to the
same Location row. A missing role remains null and does not hide the others.

All paged JSON routines use `page`/`per_page`, absolute `ord`, and
`total_count`. The batch label builder also returns parsed `geoname_id`,
`status`, and `location_label`. Status is `ok`, `not_found`, or
`invalid_geoname_id`; one bad JSON element does not abort the page.

```sql
-- MySQL
CALL maxmind_geoip2_city.find_geoinfo_by_json_ips(
    JSON_ARRAY('81.2.69.142', '2001:218::'), 1, 1, 1, 1, 40
);
SELECT maxmind_geoip2_city.build_location_label_by_geoname_id(2643743, 'ru', 1, 1, 1);
CALL maxmind_geoip2_city.build_location_labels_by_ip(
    '81.2.69.142', JSON_ARRAY('ru', 'en'), 1, 1, 1
);
CALL maxmind_geoip2_city.build_location_labels_by_json_geoname_ids(
    JSON_ARRAY(2643743, NULL, 'bad'), 'ru', 1, 1, 1, 1, 40
);

-- PostgreSQL
SELECT * FROM maxmind_geoip2_city.find_geoinfo_by_json_ips(
    '["81.2.69.142", "2001:218::"]'::jsonb, 1, 1, 1, 1, 40
);
SELECT maxmind_geoip2_city.build_location_label_by_geoname_id(2643743, 'ru', 1, 1, 1);
SELECT * FROM maxmind_geoip2_city.build_location_labels_by_ip(
    '81.2.69.142', '["ru", "en"]'::jsonb, 1, 1, 1
);
SELECT *
FROM maxmind_geoip2_city.build_location_labels_by_json_geoname_ids(
    '[2643743, null, "bad"]'::jsonb, 'ru', 1, 1, 1, 1, 40
);
```

### Dataset metadata

Every generated namespace contains one row in `dataset_metadata`. The same
row is returned as native columns by `get_dataset_metadata()`. It records:

* `run_id`, `edition_id`, and logical `archive_root`;
* `source_build_date` and database-side `imported_at`;
* `converter_version` and `schema_version`;
* `dbms`, `project_name`, and `schema_name`;
* JSON/JSONB arrays for `ip_versions`, `selected_locales`, `loaded_locales`,
  and `e_geoname_id_priority_columns`.

The metadata never stores the source URL, filesystem path, credentials,
license key, or command line. Example archives have a null
`source_build_date`. Network-only datasets use empty locale and GeoName
priority arrays. Editions processed by one config invocation share a
`run_id`.

```sql
-- MySQL
CALL maxmind_asn.get_dataset_metadata();

-- PostgreSQL
SELECT * FROM maxmind_asn.get_dataset_metadata();
```

## Verified MySQL and PostgreSQL Examples

The examples in this section were captured on 2026-08-20 from converter `1.3`
output loaded into MySQL 8 and PostgreSQL 16. The test build used IPv4 and IPv6,
all eight supported locales, and these inputs:

* `GeoLite2-City-CSV_20260818.zip`,
  `GeoLite2-Country-CSV_20260818.zip`, and
  `GeoLite2-ASN-CSV_20260818.zip` for real data;
* the bundled Example archives for Anonymous IP, Anonymous Plus, Connection
  Type, Domain, IP Risk, ISP, Residential Proxy, Static IP Score, and User
  Count.

The post-import smoke run discovered 68 MySQL routines and executed 100 calls,
then discovered 116 PostgreSQL routines and executed 136 calls. Both runs
finished with zero failed calls; the additional calls cover paging, invalid
inputs, both IP families, and alternate locale/flag combinations.

The machines, caches, and archive versions affect timings, so these numbers are
examples rather than benchmarks. MySQL client times are rounded to hundredths
of a second; the table scan checklist below also gives exact `SHOW PROFILES`
server durations. PostgreSQL times come from `psql` with `\timing on`.

### Generated routine calls

The equivalent single-IP ASN lookups are:

```sql
-- MySQL
CALL maxmind_asn.find_network_by_ip('1.0.0.1');

-- PostgreSQL
SELECT * FROM maxmind_asn.find_network_by_ip('1.0.0.1');
```

Both return:

```text
+--------+---------+------------+------------+--------------------------+--------------------------------+
| status | ip      | ip_version | network    | autonomous_system_number | autonomous_system_organization |
+--------+---------+------------+------------+--------------------------+--------------------------------+
| ok     | 1.0.0.1 |          4 | 1.0.0.0/24 |                    13335 | Cloudflare, Inc.               |
+--------+---------+------------+------------+--------------------------+--------------------------------+
```

Pagination is applied to input elements, preserves their absolute `ord`, and
keeps `total_count` on every returned row. This asks for page 2 with two items
per page:

```sql
-- MySQL
CALL maxmind_asn.find_networks_by_json_ips(
    JSON_ARRAY('1.0.0.1', '8.8.8.8', 'bad', NULL), 2, 2
);

-- PostgreSQL
SELECT * FROM maxmind_asn.find_networks_by_json_ips(
    '["1.0.0.1", "8.8.8.8", "bad", null]'::jsonb, 2, 2
);
```

```text
+-----+-------------+------+------------+------------+---------+--------------------------+--------------------------------+
| ord | total_count | ip   | status     | ip_version | network | autonomous_system_number | autonomous_system_organization |
+-----+-------------+------+------------+------------+---------+--------------------------+--------------------------------+
|   3 |           4 | bad  | invalid_ip | NULL       | NULL    | NULL                     | NULL                           |
|   4 |           4 | NULL | invalid_ip | NULL       | NULL    | NULL                     | NULL                           |
+-----+-------------+------+------------+------------+---------+--------------------------+--------------------------------+
```

Cloudflare for `1.0.0.1` and Google for `8.8.8.8`, with the same
`total_count = 4`.

The three original GeoName roles remain distinct from the effective value:

```sql
-- MySQL
CALL maxmind_geolite2_city.find_geoname_ids_by_ip('81.2.69.142');

-- PostgreSQL
SELECT *
FROM maxmind_geolite2_city.find_geoname_ids_by_ip('81.2.69.142');
```

```text
+--------+-------------+------------+----------------+--------------+------------------+------------+-------------------------------+--------------------------------+
| status | ip          | ip_version | network        | e_geoname_id | e_geoname_source | geoname_id | registered_country_geoname_id | represented_country_geoname_id |
+--------+-------------+------------+----------------+--------------+------------------+------------+-------------------------------+--------------------------------+
| ok     | 81.2.69.142 |          4 | 81.2.69.128/25 |      2651985 | geoname_id       |    2651985 |                       2635167 | NULL                           |
+--------+-------------+------------+----------------+--------------+------------------+------------+-------------------------------+--------------------------------+
```

Locale fallback is performed per label component. `Wiltshire` has no Russian
value in this build, while the continent, country, and city do:

```sql
-- MySQL
CALL maxmind_geolite2_city.build_location_labels_by_ip(
    '81.2.69.142', JSON_ARRAY('ru', 'en'), 1, 1, 1
);

-- PostgreSQL
SELECT * FROM maxmind_geolite2_city.build_location_labels_by_ip(
    '81.2.69.142', '["ru", "en"]'::jsonb, 1, 1, 1
);
```

The relevant result columns are:

| ord | locale | status | e_geoname_id | e_geoname_source | e_geoname_label |
| ---: | --- | --- | ---: | --- | --- |
| 1 | `ru` | `ok` | 2651985 | `geoname_id` | `Европа - 🇬🇧 [GB] Британия - Англия - Wiltshire - Криклейд` |
| 2 | `en` | `ok` | 2651985 | `geoname_id` | `Europe - 🇬🇧 [GB] United Kingdom - England - Wiltshire - Cricklade` |

The full result also contains `geoname_label`, `registered_country_label`, and `represented_country_label` beside their IDs.

The scalar helper uses the same fallback rules:

```sql
-- MySQL
SELECT maxmind_geolite2_city.build_location_label_by_geoname_id(
    2643743, 'ru', 1, 1, 1
) AS location_label;

-- PostgreSQL
SELECT maxmind_geolite2_city.build_location_label_by_geoname_id(
    2643743, 'ru', 1, 1, 1
) AS location_label;
```

```text
Европа - 🇬🇧 [GB] Британия - Англия - Лондон
```

Mixed-family batch lookup returns one stable User Count shape. Inapplicable
family columns are null rather than being removed from individual rows:

```sql
-- MySQL
CALL maxmind_user_count.find_networks_by_json_ips(
    JSON_ARRAY('1.0.0.1', '::1:0:0:1'), 1, 40
);

-- PostgreSQL
SELECT * FROM maxmind_user_count.find_networks_by_json_ips(
    '["1.0.0.1", "::1:0:0:1"]'::jsonb, 1, 40
);
```

| ord | total_count | ip | status | ip_version | network | ipv4_24 | ipv4_32 | ipv6_32 | ipv6_48 | ipv6_64 |
| ---: | ---: | --- | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 2 | `1.0.0.1` | `ok` | 4 | `1.0.0.0/15` | 0 | 0 | NULL | NULL | NULL |
| 2 | 2 | `::1:0:0:1` | `ok` | 6 | `::1:0:0:0/80` | NULL | NULL | 0 | 0 | 0 |

Metadata is available through either the table or the generated API:

```sql
-- MySQL
CALL maxmind_geolite2_city.get_dataset_metadata();

-- PostgreSQL
SELECT * FROM maxmind_geolite2_city.get_dataset_metadata();
```

The captured rows have the following shared logical fields and expected
run/DBMS-specific differences:

| Field | MySQL | PostgreSQL |
| --- | --- | --- |
| `run_id` | `b20260820T171800Z_715` | `b20260820T172154Z_282` |
| `edition_id` | `GeoLite2-City-CSV` | `GeoLite2-City-CSV` |
| `archive_root` | `GeoLite2-City-CSV_20260818` | `GeoLite2-City-CSV_20260818` |
| `source_build_date` | `2026-08-18` | `2026-08-18` |
| `converter_version` | `1.3` | `1.3` |
| `schema_version` | `4` | `4` |
| `dbms` | `mysql` | `postgresql` |
| `project_name` | `docs` | `docs` |
| `schema_name` | `maxmind_geolite2_city` | `maxmind_geolite2_city` |
| `ip_versions` | `[4, 6]` | `[4, 6]` |
| `selected_locales` | `["de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN"]` | same |
| `loaded_locales` | `["de", "en", "es", "fr", "ja", "pt-BR", "ru", "zh-CN"]` | same |
| `e_geoname_id_priority_columns` | `["geoname_id", "registered_country_geoname_id", "represented_country_geoname_id"]` | same |

### Physical table inventory

This build produced 42 physical tables. Every generated namespace has its own
one-row `dataset_metadata`; it is not a shared global table.

| Namespace | Tables |
| --- | --- |
| `maxmind_anonymous_ip` | `dataset_metadata`, `ipv4`, `ipv6` |
| `maxmind_anonymous_plus` | `dataset_metadata`, `ipv4`, `ipv6` |
| `maxmind_asn` | `dataset_metadata`, `ipv4`, `ipv6` |
| `maxmind_connection_type` | `dataset_metadata`, `ipv4`, `ipv6` |
| `maxmind_domain` | `dataset_metadata`, `ipv4`, `ipv6` |
| `maxmind_geolite2_city` | `city`, `country`, `dataset_metadata`, `ipv4`, `ipv6`, `subdivision1`, `subdivision2`, `timezone` |
| `maxmind_geolite2_country` | `country`, `dataset_metadata`, `ipv4`, `ipv6` |
| `maxmind_ip_risk` | `dataset_metadata`, `ipv4`, `ipv6` |
| `maxmind_isp` | `dataset_metadata`, `ipv4`, `ipv6` |
| `maxmind_residential_proxy` | `dataset_metadata`, `ipv4`, `ipv6` |
| `maxmind_static_ip_score` | `dataset_metadata`, `ipv4`, `ipv6` |
| `maxmind_user_count` | `dataset_metadata`, `ipv4`, `ipv6` |

The following checklist is valid unchanged in both MySQL and PostgreSQL and
touches every physical table. The `ORDER BY` makes sample rows reproducible.

```sql
-- GeoIP2 Anonymous IP
SELECT * FROM maxmind_anonymous_ip.dataset_metadata;
SELECT * FROM maxmind_anonymous_ip.ipv4;
SELECT * FROM maxmind_anonymous_ip.ipv6;

-- GeoIP Anonymous Plus
SELECT * FROM maxmind_anonymous_plus.dataset_metadata;
SELECT * FROM maxmind_anonymous_plus.ipv4;
SELECT * FROM maxmind_anonymous_plus.ipv6;

-- GeoLite2 ASN
SELECT * FROM maxmind_asn.dataset_metadata;
SELECT * FROM maxmind_asn.ipv4;
SELECT * FROM maxmind_asn.ipv6;

-- GeoIP2 Connection Type
SELECT * FROM maxmind_connection_type.dataset_metadata;
SELECT * FROM maxmind_connection_type.ipv4;
SELECT * FROM maxmind_connection_type.ipv6;

-- GeoIP2 Domain
SELECT * FROM maxmind_domain.dataset_metadata;
SELECT * FROM maxmind_domain.ipv4;
SELECT * FROM maxmind_domain.ipv6;

-- GeoLite2 City
SELECT * FROM maxmind_geolite2_city.city;
SELECT * FROM maxmind_geolite2_city.country;
SELECT * FROM maxmind_geolite2_city.dataset_metadata;
SELECT * FROM maxmind_geolite2_city.ipv4;
SELECT * FROM maxmind_geolite2_city.ipv6;
SELECT * FROM maxmind_geolite2_city.subdivision1;
SELECT * FROM maxmind_geolite2_city.subdivision2;
SELECT * FROM maxmind_geolite2_city.timezone;

-- GeoLite2 Country
SELECT * FROM maxmind_geolite2_country.country;
SELECT * FROM maxmind_geolite2_country.dataset_metadata;
SELECT * FROM maxmind_geolite2_country.ipv4;
SELECT * FROM maxmind_geolite2_country.ipv6;

-- GeoIP2 IP Risk
SELECT * FROM maxmind_ip_risk.dataset_metadata;
SELECT * FROM maxmind_ip_risk.ipv4;
SELECT * FROM maxmind_ip_risk.ipv6;

-- GeoIP2 ISP
SELECT * FROM maxmind_isp.dataset_metadata;
SELECT * FROM maxmind_isp.ipv4;
SELECT * FROM maxmind_isp.ipv6;

-- GeoIP Residential Proxy
SELECT * FROM maxmind_residential_proxy.dataset_metadata;
SELECT * FROM maxmind_residential_proxy.ipv4;
SELECT * FROM maxmind_residential_proxy.ipv6;

-- GeoIP2 Static IP Score
SELECT * FROM maxmind_static_ip_score.dataset_metadata;
SELECT * FROM maxmind_static_ip_score.ipv4;
SELECT * FROM maxmind_static_ip_score.ipv6;

-- GeoIP2 User Count
SELECT * FROM maxmind_user_count.dataset_metadata;
SELECT * FROM maxmind_user_count.ipv4;
SELECT * FROM maxmind_user_count.ipv6;
```

All 42 statements completed successfully. The first result from every distinct
network table is summarized below. `start_ip` and `last_ip` are omitted from the
compact summary: MySQL renders them as integers, while PostgreSQL renders them
as address boundaries, as shown in the full City example that follows.
Each of the 12 `dataset_metadata` statements returned exactly one row with the
14-column shape shown in the metadata example above and its own edition/schema
values.

| Table | First result: `network`; edition-specific values |
| --- | --- |
| `maxmind_anonymous_ip.ipv4` | `1.2.0.0/16`; anonymous = 1, anonymous VPN = 1, other flags = NULL |
| `maxmind_anonymous_ip.ipv6` | `abcd:1000::/112`; anonymous = 1, public proxy = 1, other flags = NULL |
| `maxmind_anonymous_plus.ipv4` | `1.2.0.0/32`; anonymous = 1, anonymous VPN = 1, provider/confidence/last-seen = NULL |
| `maxmind_anonymous_plus.ipv6` | `2001:480:3a::/64`; anonymous = 1, public proxy = 1, provider/confidence/last-seen = NULL |
| `maxmind_asn.ipv4` | `1.0.0.0/24`; ASN 13335, `Cloudflare, Inc.` |
| `maxmind_asn.ipv6` | `2001:200::/37`; ASN 2500, `WIDE Project` |
| `maxmind_connection_type.ipv4` | `1.0.0.0/24`; `Cable/DSL` |
| `maxmind_connection_type.ipv6` | `2003::/24`; `Cable/DSL` |
| `maxmind_domain.ipv4` | `1.2.0.0/16`; `maxmind.com` |
| `maxmind_domain.ipv6` | `2a02:2770:3::/64`; `sgotti.org` |
| `maxmind_geolite2_city.ipv4` | `1.0.0.0/24`; effective ID 2077456 from registered-country ID |
| `maxmind_geolite2_city.ipv6` | `2001:200::/32`; effective ID 1861060, latitude 35.6900, longitude 139.6900 |
| `maxmind_geolite2_country.ipv4` | `1.0.0.0/24`; effective ID 2077456 from registered-country ID |
| `maxmind_geolite2_country.ipv6` | `2001:200::/32`; effective/original/registered ID 1861060 |
| `maxmind_ip_risk.ipv4` | `214.2.3.0/30`; risk 25.00, anonymous = 1, anonymous VPN = 1 |
| `maxmind_ip_risk.ipv6` | no rows in `GeoIP2-IP-Risk-CSV_Example.zip` |
| `maxmind_isp.ipv4` | `1.0.128.0/17`; ISP and organization `TOT Public Company Limited` |
| `maxmind_isp.ipv6` | `2001:1700::/27`; ASN 6730, `Sunrise Communications AG` |
| `maxmind_residential_proxy.ipv4` | `6.0.42.17/32`; `novada`, confidence 95, last seen 2026-05-14 |
| `maxmind_residential_proxy.ipv6` | `2001:480:1b20:fb4f::/64`; `lumiproxy`, confidence 65, last seen 2026-04-09 |
| `maxmind_static_ip_score.ipv4` | `1.0.0.0/15`; score 0.01 |
| `maxmind_static_ip_score.ipv6` | `::1:0:0:0/80`; score 1.48 |
| `maxmind_user_count.ipv4` | `1.0.0.0/15`; `ipv4_24 = 0`, `ipv4_32 = 0` |
| `maxmind_user_count.ipv6` | `::1:0:0:0/80`; `ipv6_32 = 0`, `ipv6_48 = 0`, `ipv6_64 = 0` |

The normalized City dimension tables returned these first rows:

| Table | First result |
| --- | --- |
| `maxmind_geolite2_city.timezone` | `id = 1`, `Africa/Abidjan` |
| `maxmind_geolite2_city.country` | `id = 1`, continent Asia in all configured locales, no country ISO/name |
| `maxmind_geolite2_city.subdivision1` | `id = 1`, ISO `02`, `Canillo` / `Канильо` |
| `maxmind_geolite2_city.subdivision2` | `id = 1`, ISO `BAB`, `Babek Rayon`; other locale names NULL |
| `maxmind_geolite2_city.city` | GeoName 11797, country 110, subdivision1 1115, `Afrā`, timezone 263 |

This is the complete first City IPv4 row in MySQL:

```text
mysql> SELECT * FROM maxmind_geolite2_city.ipv4;
+------------+----------+----------+--------------+-----------------------+------------+-------------------------------+--------------------------------+--------------------+-----------------------+-------------+----------+-----------+-----------------+------------+
| network    | start_ip | last_ip  | e_geoname_id | e_geoname_source_code | geoname_id | registered_country_geoname_id | represented_country_geoname_id | is_anonymous_proxy | is_satellite_provider | postal_code | latitude | longitude | accuracy_radius | is_anycast |
+------------+----------+----------+--------------+-----------------------+------------+-------------------------------+--------------------------------+--------------------+-----------------------+-------------+----------+-----------+-----------------+------------+
| 1.0.0.0/24 | 16777216 | 16777471 |      2077456 |                     2 | NULL       |                       2077456 | NULL                           |                  0 |                     0 | NULL        | NULL     | NULL      | NULL            | NULL       |
+------------+----------+----------+--------------+-----------------------+------------+-------------------------------+--------------------------------+--------------------+-----------------------+-------------+----------+-----------+-----------------+------------+
```

PostgreSQL returns the same logical row, with native `inet` boundaries and
booleans:

```text
maxmind=> SELECT * FROM maxmind_geolite2_city.ipv4;
  network   | start_ip |  last_ip  | e_geoname_id | e_geoname_source_code | geoname_id | registered_country_geoname_id | represented_country_geoname_id | is_anonymous_proxy | is_satellite_provider | postal_code | latitude | longitude | accuracy_radius | is_anycast
------------+----------+-----------+--------------+-----------------------+------------+-------------------------------+--------------------------------+--------------------+-----------------------+-------------+----------+-----------+-----------------+-----------
 1.0.0.0/24 | 1.0.0.0  | 1.0.0.255 |      2077456 |                     2 |            |                       2077456 |                                | f                  | f                     |             |          |           |                 |
(1 row)

```

The real Country archive provides all configured locale columns:

```sql
SELECT *
FROM maxmind_geolite2_country.country
ORDER BY geoname_id
LIMIT 5;
```

| geoname_id | continent | iso | emoji | name_en | name_ru | name_de | name_es | name_fr | name_ja | name_pt-BR | name_zh-CN | EU |
| ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 49518 | AF / Africa / Африка | RW | 🇷🇼 | Rwanda | Руанда | Ruanda | Ruanda | Rwanda | ルワンダ共和国 | Ruanda | 卢旺达 | 0 / `f` |
| 51537 | AF / Africa / Африка | SO | 🇸🇴 | Somalia | Сомали | Somalia | Somalia | Somalie | ソマリア | Somália | 索马里 | 0 / `f` |
| 69543 | AS / Asia / Азия | YE | 🇾🇪 | Yemen | Йемен | Jemen | Yemen | Yémen | イエメン共和国 | Iêmen | 也门 | 0 / `f` |
| 99237 | AS / Asia / Азия | IQ | 🇮🇶 | Iraq | Ирак | Irak | Irak | Irak | イラク共和国 | Iraque | 伊拉克 | 0 / `f` |
| 102358 | AS / Asia / Азия | SA | 🇸🇦 | Saudi Arabia | Саудовская Аравия | Saudi-Arabien | Arabia Saudí | Arabie saoudite | サウジアラビア王国 | Arábia Saudita | 沙特阿拉伯 | 0 / `f` |

### Useful direct SQL

These are queries over the generated tables for analyses that are intentionally
not part of the lookup API.

Find networks whose effective location came from
`registered_country_geoname_id` rather than `geoname_id`:

```sql
SELECT network,
       geoname_id,
       registered_country_geoname_id,
       represented_country_geoname_id,
       e_geoname_id,
       e_geoname_source_code
FROM maxmind_geolite2_city.ipv4
WHERE e_geoname_source_code = 2
ORDER BY start_ip
LIMIT 5;
```

| network | geoname_id | registered_country_geoname_id | represented_country_geoname_id | e_geoname_id | source code |
| --- | ---: | ---: | ---: | ---: | ---: |
| `1.0.0.0/24` | NULL | 2077456 | NULL | 2077456 | 2 |
| `1.1.1.0/24` | NULL | 2077456 | NULL | 2077456 | 2 |
| `2.58.104.0/24` | NULL | 798544 | NULL | 798544 | 2 |
| `2.58.107.0/24` | NULL | 798544 | NULL | 798544 | 2 |
| `5.200.5.0/24` | NULL | 2750405 | NULL | 2750405 | 2 |

Resolve all three country roles independently. Repeated GeoName IDs across many
networks are expected: a Location row is shared lookup data, not an IP owner.

```sql
SELECT n.network,
       location.iso_code AS location_iso,
       registered.iso_code AS registered_iso,
       represented.iso_code AS represented_iso
FROM maxmind_geolite2_country.ipv4 AS n
LEFT JOIN maxmind_geolite2_country.country AS location
       ON location.geoname_id = n.geoname_id
LEFT JOIN maxmind_geolite2_country.country AS registered
       ON registered.geoname_id = n.registered_country_geoname_id
LEFT JOIN maxmind_geolite2_country.country AS represented
       ON represented.geoname_id = n.represented_country_geoname_id
WHERE n.geoname_id <> n.registered_country_geoname_id
ORDER BY n.start_ip
LIMIT 5;
```

| network | location_iso | registered_iso | represented_iso |
| --- | --- | --- | --- |
| `1.32.194.0/24` | `TW` | `SG` | NULL |
| `1.32.197.0/24` | `TW` | `SG` | NULL |
| `1.32.202.0/25` | `TW` | `SG` | NULL |
| `1.32.203.0/25` | `TW` | `SG` | NULL |
| `1.32.204.0/25` | `TW` | `SG` | NULL |

Find ASNs represented by the largest number of IPv4 CIDR rows in the current
archive. This measures rows, not address-space size:

```sql
SELECT autonomous_system_number,
       autonomous_system_organization,
       COUNT(*) AS ipv4_networks
FROM maxmind_asn.ipv4
GROUP BY autonomous_system_number, autonomous_system_organization
ORDER BY ipv4_networks DESC
LIMIT 5;
```

| ASN | Organization | IPv4 networks |
| ---: | --- | ---: |
| 7922 | Comcast Cable Communications, LLC | 24897 |
| 7018 | AT&T Enterprises, LLC | 20326 |
| 701 | Verizon Business | 14436 |
| 4134 | Chinanet | 9389 |
| 5650 | Frontier Communications of America, Inc. | 9339 |

Audit effective-location coverage. The boolean aggregate syntax differs between
the databases:

```sql
-- MySQL
SELECT COUNT(*) AS networks,
       SUM(e_geoname_id IS NULL) AS without_e_geoname_id,
       ROUND(100.0 * SUM(e_geoname_id IS NULL) / COUNT(*), 2)
           AS without_e_geoname_pct
FROM maxmind_geolite2_city.ipv4;

-- PostgreSQL
SELECT COUNT(*) AS networks,
       COUNT(*) FILTER (WHERE e_geoname_id IS NULL)
           AS without_e_geoname_id,
       ROUND(
           100.0 * COUNT(*) FILTER (WHERE e_geoname_id IS NULL) / COUNT(*),
           2
       ) AS without_e_geoname_pct
FROM maxmind_geolite2_city.ipv4;
```

```text
+----------+----------------------+-----------------------+
| networks | without_e_geoname_id | without_e_geoname_pct |
+----------+----------------------+-----------------------+
|  3704456 |                    0 |                  0.00 |
+----------+----------------------+-----------------------+
```

Find Example User Count networks with the largest combined IPv4 estimates:

```sql
SELECT network, ipv4_24, ipv4_32
FROM maxmind_user_count.ipv4
ORDER BY (ipv4_24 + ipv4_32) DESC, start_ip
LIMIT 5;
```

| network | ipv4_24 | ipv4_32 |
| --- | ---: | ---: |
| `1.2.3.4/32` | 4 | 3 |
| `214.2.3.4/32` | 4 | 3 |
| `1.2.3.5/32` | 4 | 1 |
| `1.2.3.6/32` | 4 | 1 |
| `214.2.3.5/32` | 4 | 1 |

## Tests

Example ZIP archives live in `test/data/`. The test configs use paths relative
to the `test/` directory, such as `data/GeoLite2-Country-CSV_Example.zip`.

`test/count-data.sh` counts rows directly from the source ZIP archives. It is
useful for checking generated database row counts after an import:

```bash
./test/count-data.sh
./test/count-data.sh GeoLite2-Country-CSV_Example.zip
```

After loading the test SQL into MySQL or PostgreSQL, run
`test/select-counts.sql` against the database and compare the results with
`count-data.sh`. The SQL covers all schemas used by the current test configs,
including network-only schemas, City/Country, and Enterprise. Its second result
set checks that every `dataset_metadata` table contains exactly one row.

Run `test/api-smoke.mysql.sql` or `test/api-smoke.postgresql.sql` to exercise
strict IP validation, ordered mixed batches, metadata safety, effective-source
integrity, configurable page boundaries and `total_count`, `no_location`,
per-component locale fallback, three-role location labels, and
synthetic registered/represented-country fallbacks. Synthetic rows are
inserted inside a transaction and rolled back.
