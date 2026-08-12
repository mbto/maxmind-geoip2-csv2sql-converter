# MaxMind CSV to SQL

Single Bash entrypoint for generating MySQL 8 or PostgreSQL import packages from
MaxMind GeoIP/GeoIP2/GeoLite2 CSV ZIP archives.

Current release config format: `v1.2`.

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
`[GeoIP2-Domain-CSV.download]`, then falls back to an unscoped section such as
`[download]`. Package-level execution, output, cleanup, archive, and client
settings live in `[settings]` because one config generates one output package
and one `loader.sh`; the database type comes from the config filename suffix,
such as `.mysql.ini` or `.postgresql.ini`.
Single-edition configs can still use plain `[download]`, `[database]`,
`[convert]`, and `[columns.<table>]` sections.

Example MySQL package settings:

```ini
[settings]
# MySQL client command; values: command name from PATH or path to executable.
mysql_command = mysql
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

For one-off debug timing without editing the config, set `ON_DEBUG=true` in the
environment before running the converter. Debug timing prints each measured step and
its elapsed time to stderr.

Edition-level conversion settings, including custom SQL generator selection,
belong in `[<edition>.convert]`:

```ini
[GeoIP2-Domain-CSV.convert]
# SQL Bash generator file; values: functions.bash or relative/absolute path to a custom functions.bash.
sql_bash_generator_file = functions.bash
# IP block versions to import; values: 4, 6, or comma-separated list 4,6.
ip_versions = 4,6
# Locations CSV locales to import; values: en, ru, de, es, fr, ja, pt-BR, zh-CN, comma-separated.
locales = en
# Blocks CSV columns used, in priority order, to derive v_geoname_id; values: geoname_id, registered_country_geoname_id, represented_country_geoname_id.
v_geoname_id_priority_columns = geoname_id,registered_country_geoname_id,represented_country_geoname_id
```

With the default `functions.bash` value, the converter looks for
`generators/<project_name>/functions.bash` relative to the config directory and
then falls back to `generators/default/functions.bash`.

Each processed MaxMind edition is validated against the root directory inside
the ZIP, for example `GeoIP2-Domain-CSV_Example/` or `GeoLite2-City-CSV_20260605/`.

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

[GeoIP2-Domain-CSV.download]
# MaxMind edition expected by this section; values: one edition_id from [editions].
edition_id = GeoIP2-Domain-CSV
# MaxMind license key for official downloads; values: a string, or empty for local archives and URLs without ${license_key}.
license_key = your-maxmind-license-key
# MaxMind ZIP archive source; values: HTTP(S) URL or local path; supports ${edition_id}, ${license_key}, ${database_type}, and ${project_name}.
source_archive_uri = https://download.maxmind.com/app/geoip_download?edition_id=${edition_id}&license_key=${license_key}&suffix=zip
...
```

Mirror and local archive examples:

```ini
# Mirror examples:
# source_archive_uri = https://some.maxmind.csv.repository/${edition_id}.zip
# source_archive_uri = ../test/data/GeoIP2-Domain-CSV_Example.zip
# source_archive_uri = C:\data\GeoIP2-Domain-CSV_20260605.zip
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
`converted/default.mysql/csv/GeoIP2-Connection-Type-CSV_Example/`, to avoid
filename collisions between editions and between MySQL/PostgreSQL runs.

Important generated files:

* `00_create_raw.sql`, `10_load_raw.sql`, `20_transform_stage.sql`,
  `90_indexes_stage.sql`, `98_promote.sql`, `99_routines.sql`,
  `100_cleanup_raw.sql`.
* `load_data.sql` - full import script.
* `loader.sh` - runs `load_data.sql` with `mysql` or `psql`.

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

Location databases create normalized location tables plus IP block tables.
City and Enterprise configs create `timezone`, `country`, `subdivision1`,
`subdivision2`, `city`, `ipv4`, and `ipv6`. Enterprise also creates `isp` and
adds foreign keys from `ipv4/ipv6.isp_id` to `isp.isp_id`.

Country configs create `country`, `ipv4`, and `ipv6`.

Network-only databases create only `ipv4` and `ipv6`. The `network` column is
the natural primary key; generated `start_ip`/`last_ip` columns support range
lookup/indexing. In MySQL these range columns are numeric values, while in
PostgreSQL they are `inet` values. PostgreSQL `inet` always has a prefix length;
generated range boundaries use host prefixes (`/32` for IPv4 and `/128` for
IPv6), not the source network prefix. These datasets do not have synthetic
foreign keys because MaxMind provides no separate stable key beyond `network`.

## Output Columns

Project configs can choose output columns via `[columns.<table>]` or
`[<edition>.columns.<table>]` sections.
`name = true` and `continent_name = true` create one column per locale from
`convert.locales`, such as `name_en` and `name_ru`.

Some columns are required by the default generator:

* all datasets: IP `network` and range columns
* location datasets: primary keys and `v_geoname_id`
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
...
```

## Lookup Helpers

Location databases generate:

* `find_network_by_ip(ip)` - one IP address; MySQL `VARCHAR(45)`, PostgreSQL `text`.
* `find_geoname_id_by_ip(ip)` - one IP address; MySQL `VARCHAR(45)`, PostgreSQL `text`.
* `find_geoinfo_by_ip(ip)` - one IP address; MySQL `VARCHAR(45)`, PostgreSQL `text`.
* `build_location_mix(geoname_id, append_emoji)` - one geoname id and emoji flag; MySQL `INT UNSIGNED, INT UNSIGNED`, PostgreSQL `integer, integer`.
* `build_location_mix_with_iso_code(geoname_id)` - one geoname id; MySQL `INT UNSIGNED`, PostgreSQL `integer`.
* `find_networks_by_ips_json(ips_json)` - JSON array of IP strings; MySQL `JSON`, PostgreSQL `jsonb`.
* `find_geoname_ids_by_ips_json(ips_json)` - JSON array of IP strings; MySQL `JSON`, PostgreSQL `jsonb`.
* `find_geoinfo_by_ips_json(ips_json)` - JSON array of IP strings; MySQL `JSON`, PostgreSQL `jsonb`.
* `find_geoinfo_by_geoname_ids_json(geoname_ids_json)` - JSON array of geoname ids; MySQL `JSON`, PostgreSQL `jsonb`.
* `build_location_mixes_by_geoname_ids_json(geoname_ids_json, append_emoji)` - JSON array of geoname ids and emoji flag; MySQL `JSON, INT UNSIGNED`, PostgreSQL `jsonb, integer`.

PostgreSQL also generates narrowed network helpers when the corresponding IP
version is enabled:

* `find_ipv4_network_by_ip(ip)` - one IPv4 address; PostgreSQL `text`.
* `find_ipv6_network_by_ip(ip)` - one IPv6 address; PostgreSQL `text`.
* `find_ipv4_networks_by_ips_json(ips_json)` - JSON array of IPv4 strings; PostgreSQL `jsonb`.
* `find_ipv6_networks_by_ips_json(ips_json)` - JSON array of IPv6 strings; PostgreSQL `jsonb`.

Network-only databases do not generate geoname lookup helpers because they have
no location tables. All databases generate `find_network_by_ip`, which returns
the matching row from `ipv4` or `ipv6` with `network` and configured data
columns. In MySQL, this procedure returns the column set for the matching IP
family, so editions with different IPv4 and IPv6 columns can return different
result shapes. PostgreSQL lookup functions keep one static `RETURNS TABLE`
shape, using the union of configured IPv4 and IPv6 columns; use the narrowed
PostgreSQL helpers when you need only the IPv4 or IPv6 output columns.

All databases also generate `find_networks_by_ips_json`, which accepts a JSON
array of IP strings. MySQL chooses the batch result shape from the input:
IPv4-only inputs return IPv4 columns, IPv6-only inputs return IPv6 columns, and
mixed or ambiguous inputs return the merged IPv4+IPv6 column set. Location
databases generate the other JSON batch helpers. Batch helpers return one row
per input item and include a 1-based `ord` column so the original JSON order
can be restored after downstream joins. The MySQL batch network helper uses an
internal temporary result table. MySQL temporary tables are scoped to the
current connection, so concurrent sessions can safely use the same internal
table name; only avoid running multiple statements concurrently on the same
client connection.

JSON batch examples from `maxmind_geoip2_city` loaded from the bundled test
data:

```text
maxmind_geoip2_city> CALL find_networks_by_ips_json(JSON_ARRAY(
    '81.2.69.142','89.160.20.112','2001:218::'
));
+------+---------------+------------------+--------------+------------+-------------------------------+--------------------------------+--------------------+-----------------------+-------------+----------+-----------+-----------------+------------+
| ord  | ip            | network          | v_geoname_id | geoname_id | registered_country_geoname_id | represented_country_geoname_id | is_anonymous_proxy | is_satellite_provider | postal_code | latitude | longitude | accuracy_radius | is_anycast |
+------+---------------+------------------+--------------+------------+-------------------------------+--------------------------------+--------------------+-----------------------+-------------+----------+-----------+-----------------+------------+
|    1 | 81.2.69.142   | 81.2.69.142/31   |      2643743 |    2643743 |                       6252001 |                           NULL |                  0 |                     0 | NULL        |  51.5142 |   -0.0931 |              10 |       NULL |
|    2 | 89.160.20.112 | 89.160.20.112/28 |      2694762 |    2694762 |                       2921044 |                           NULL |                  0 |                     0 | NULL        |  58.4167 |   15.6167 |              76 |       NULL |
|    3 | 2001:218::    | 2001:218::/32    |      1861060 |    1861060 |                       1861060 |                           NULL |                  0 |                     0 | NULL        |  35.6854 |  139.7531 |             100 |       NULL |
+------+---------------+------------------+--------------+------------+-------------------------------+--------------------------------+--------------------+-----------------------+-------------+----------+-----------+-----------------+------------+
```

```text
maxmind_geoip2_city> CALL find_geoname_ids_by_ips_json(JSON_ARRAY(
    '2.2.3.0','2.3.3.0','2.125.160.216','67.43.156.0',
    '81.2.69.142','81.2.69.144','81.2.69.160','81.2.69.192',
    '89.160.20.112','89.160.20.128','149.101.100.0','175.16.199.0',
    '202.196.224.0','214.0.0.0','214.0.1.0','214.78.120.0',
    '216.160.83.56','2001:218::','2001:220::','2001:230::',
    '2001:238::','2001:240::','2001:250::','2001:252::',
    '2001:254::','2001:256::','2001:258::','2001:260::',
    '2001:268::','2001:270::'
));
+------+---------------+------------+
| ord  | ip            | geoname_id |
+------+---------------+------------+
|    1 | 2.2.3.0       |    2655045 |
|    2 | 2.3.3.0       |    6255148 |
|    3 | 2.125.160.216 |    2655045 |
|    4 | 67.43.156.0   |    1252634 |
|    5 | 81.2.69.142   |    2643743 |
|    6 | 81.2.69.144   |    2643743 |
|    7 | 81.2.69.160   |    2643743 |
|    8 | 81.2.69.192   |    2643743 |
|    9 | 89.160.20.112 |    2694762 |
|   10 | 89.160.20.128 |    2694762 |
|   11 | 149.101.100.0 |    6252001 |
|   12 | 175.16.199.0  |    2038180 |
|   13 | 202.196.224.0 |    1694008 |
|   14 | 214.0.0.0     |    1880252 |
|   15 | 214.0.1.0     |    2158177 |
|   16 | 214.78.120.0  |    5391811 |
|   17 | 216.160.83.56 |    5803556 |
|   18 | 2001:218::    |    1861060 |
|   19 | 2001:220::    |    1835841 |
|   20 | 2001:230::    |    1835841 |
|   21 | 2001:238::    |    1668284 |
|   22 | 2001:240::    |    1861060 |
|   23 | 2001:250::    |    1814991 |
|   24 | 2001:252::    |    1814991 |
|   25 | 2001:254::    |    1814991 |
|   26 | 2001:256::    |    1814991 |
|   27 | 2001:258::    |    1861060 |
|   28 | 2001:260::    |    1861060 |
|   29 | 2001:268::    |    1861060 |
|   30 | 2001:270::    |    1835841 |
+------+---------------+------------+
```

```text
maxmind_geoip2_city> CALL find_geoinfo_by_ips_json(JSON_ARRAY(
    '81.2.69.142','89.160.20.112','2001:218::'
));
+------+---------------+------------+------------------+------------------------------------------------------+------------------------------------------------------------+-------------------------------------------+---------------------------------------------+--------------------------------------------------------+-----------------------------------------------------------------------+---------------------------------------------+-----------------------------+----------------------------------------------------------------------+
| ord  | ip            | geoname_id | country_iso_code | location_en                                          | location_ru                                                | location_de                               | location_es                                 | location_fr                                            | location_ja                                                           | location_pt_br                              | location_zh_cn              | location_mix                                                         |
+------+---------------+------------+------------------+------------------------------------------------------+------------------------------------------------------------+-------------------------------------------+---------------------------------------------+--------------------------------------------------------+-----------------------------------------------------------------------+---------------------------------------------+-----------------------------+----------------------------------------------------------------------+
|    1 | 81.2.69.142   |    2643743 | GB               | Europe - United Kingdom - England - London           | Европа - Великобритания - Лондон                           | Europa - Vereinigtes Königreich - London  | Europa - Reino Unido - Inglaterra - Londres | Europe - Royaume-Uni - Angleterre - Londres            | ヨーロッパ - イギリス - ロンドン                                      | Europa - Reino Unido - Inglaterra - Londres | 欧洲 - 英国                 | Европа - Великобритания - England - Лондон                           |
|    2 | 89.160.20.112 |    2694762 | SE               | Europe - Sweden - Östergötland County - Linköping    | Европа - Швеция                                            | Europa - Schweden - Linköping             | Europa - Suecia                             | Europe - Suède - Comté d'Östergötland - Linköping      | ヨーロッパ - スウェーデン王国 - リンシェーピング                      | Europa - Suécia                             | 欧洲 - 瑞典 - 林雪平        | Европа - Швеция - Östergötland County - Linköping                    |
|    3 | 2001:218::    |    1861060 | JP               | Asia - Japan                                         | Азия - Япония                                              | Asien - Japan                             | Asia - Japón                                | Asie - Japon                                           | アジア - 日本                                                         | Ásia - Japão                                | 亚洲 - 日本                 | Азия - Япония                                                        |
+------+---------------+------------+------------------+------------------------------------------------------+------------------------------------------------------------+-------------------------------------------+---------------------------------------------+--------------------------------------------------------+-----------------------------------------------------------------------+---------------------------------------------+-----------------------------+----------------------------------------------------------------------+
```

```text
maxmind_geoip2_city> CALL find_geoinfo_by_geoname_ids_json(JSON_ARRAY(
    2643743,2694762,1861060
));
+------+------------+------------------+------------------------------------------------------+------------------------------------------------------------+-------------------------------------------+---------------------------------------------+--------------------------------------------------------+-----------------------------------------------------------------------+---------------------------------------------+-----------------------------+----------------------------------------------------------------------+
| ord  | geoname_id | country_iso_code | location_en                                          | location_ru                                                | location_de                               | location_es                                 | location_fr                                            | location_ja                                                           | location_pt_br                              | location_zh_cn              | location_mix                                                         |
+------+------------+------------------+------------------------------------------------------+------------------------------------------------------------+-------------------------------------------+---------------------------------------------+--------------------------------------------------------+-----------------------------------------------------------------------+---------------------------------------------+-----------------------------+----------------------------------------------------------------------+
|    1 |    2643743 | GB               | Europe - United Kingdom - England - London           | Европа - Великобритания - Лондон                           | Europa - Vereinigtes Königreich - London  | Europa - Reino Unido - Inglaterra - Londres | Europe - Royaume-Uni - Angleterre - Londres            | ヨーロッパ - イギリス - ロンドン                                      | Europa - Reino Unido - Inglaterra - Londres | 欧洲 - 英国                 | Европа - Великобритания - England - Лондон                           |
|    2 |    2694762 | SE               | Europe - Sweden - Östergötland County - Linköping    | Европа - Швеция                                            | Europa - Schweden - Linköping             | Europa - Suecia                             | Europe - Suède - Comté d'Östergötland - Linköping      | ヨーロッパ - スウェーデン王国 - リンシェーピング                      | Europa - Suécia                             | 欧洲 - 瑞典 - 林雪平        | Европа - Швеция - Östergötland County - Linköping                    |
|    3 |    1861060 | JP               | Asia - Japan                                         | Азия - Япония                                              | Asien - Japan                             | Asia - Japón                                | Asie - Japon                                           | アジア - 日本                                                         | Ásia - Japão                                | 亚洲 - 日本                 | Азия - Япония                                                        |
+------+------------+------------------+------------------------------------------------------+------------------------------------------------------------+-------------------------------------------+---------------------------------------------+--------------------------------------------------------+-----------------------------------------------------------------------+---------------------------------------------+-----------------------------+----------------------------------------------------------------------+
```

```text
maxmind_geoip2_city> CALL build_location_mixes_by_geoname_ids_json(JSON_ARRAY(
    102358,130758,174982,248816,272103,285570,290291,290557,294640,298795,
    587116,630336,660013,690791,719819,732800,783754,798544,798549,1252634,
    1668284,1694008,1814991,1819730,1835841,1861060,1880251,1880252,2017370,2038180
), 1);
+------+------------+-----------------------------------------+--------------------------------------------+
| ord  | geoname_id | location_mix                            | location_mix_iso                           |
+------+------------+-----------------------------------------+--------------------------------------------+
|    1 |     102358 | Азия - 🇸🇦 Саудовская Аравия              | Азия - [SA] Саудовская Аравия              |
|    2 |     130758 | Азия - 🇮🇷 Иран                           | Азия - [IR] Иран                           |
|    3 |     174982 | Азия - 🇦🇲 Армения                        | Азия - [AM] Армения                        |
|    4 |     248816 | Азия - 🇯🇴 Иордания                       | Азия - [JO] Иордания                       |
|    5 |     272103 | Азия - 🇱🇧 Ливан                          | Азия - [LB] Ливан                          |
|    6 |     285570 | Азия - 🇰🇼 Кувейт                         | Азия - [KW] Кувейт                         |
|    7 |     290291 | Азия - 🇧🇭 Бахрейн                        | Азия - [BH] Бахрейн                        |
|    8 |     290557 | Азия - 🇦🇪 Объединенные Арабские Эмираты  | Азия - [AE] Объединенные Арабские Эмираты  |
|    9 |     294640 | Азия - 🇮🇱 Израиль                        | Азия - [IL] Израиль                        |
|   10 |     298795 | Азия - 🇹🇷 Турция                         | Азия - [TR] Турция                         |
|   11 |     587116 | Азия - 🇦🇿 Азербайджан                    | Азия - [AZ] Азербайджан                    |
|   12 |     630336 | Европа - 🇧🇾 Беларусь                     | Европа - [BY] Беларусь                     |
|   13 |     660013 | Европа - 🇫🇮 Финляндия                    | Европа - [FI] Финляндия                    |
|   14 |     690791 | Европа - 🇺🇦 Украина                      | Европа - [UA] Украина                      |
|   15 |     719819 | Европа - 🇭🇺 Венгрия                      | Европа - [HU] Венгрия                      |
|   16 |     732800 | Европа - 🇧🇬 Болгария                     | Европа - [BG] Болгария                     |
|   17 |     783754 | Европа - 🇦🇱 Албания                      | Европа - [AL] Албания                      |
|   18 |     798544 | Европа - 🇵🇱 Польша                       | Европа - [PL] Польша                       |
|   19 |     798549 | Европа - 🇷🇴 Румыния                      | Европа - [RO] Румыния                      |
|   20 |    1252634 | Азия - 🇧🇹 Бутан                          | Азия - [BT] Бутан                          |
|   21 |    1668284 | Азия - 🇹🇼 Тайвань                        | Азия - [TW] Тайвань                        |
|   22 |    1694008 | Азия - 🇵🇭 Филиппины                      | Азия - [PH] Филиппины                      |
|   23 |    1814991 | Азия - 🇨🇳 Китай                          | Азия - [CN] Китай                          |
|   24 |    1819730 | Азия - 🇭🇰 Гонконг                        | Азия - [HK] Гонконг                        |
|   25 |    1835841 | Азия - 🇰🇷 Южная Корея                    | Азия - [KR] Южная Корея                    |
|   26 |    1861060 | Азия - 🇯🇵 Япония                         | Азия - [JP] Япония                         |
|   27 |    1880251 | Азия - 🇸🇬 Сингапур                       | Азия - [SG] Сингапур                       |
|   28 |    1880252 | Азия - 🇸🇬 Сингапур                       | Азия - [SG] Сингапур                       |
|   29 |    2017370 | Европа - 🇷🇺 Россия                       | Европа - [RU] Россия                       |
|   30 |    2038180 | Азия - 🇨🇳 Китай - Jilin Sheng - Чанчунь  | Азия - [CN] Китай - Jilin Sheng - Чанчунь  |
+------+------------+-----------------------------------------+--------------------------------------------+
```

MySQL examples from the bundled test data loaded into MySQL 8.0:

Network-only `find_network_by_ip` outputs from the same MySQL test data. Some
schemas use different IPs because the bundled example ranges are
dataset-specific:

#### GeoIP2-Anonymous-IP-CSV (`maxmind_anonymous_ip`):

```text
maxmind_anonymous_ip> CALL find_network_by_ip('81.2.69.142');
+--------------+--------------+------------------+---------------------+-----------------+------------------+----------------------+
| network      | is_anonymous | is_anonymous_vpn | is_hosting_provider | is_public_proxy | is_tor_exit_node | is_residential_proxy |
+--------------+--------------+------------------+---------------------+-----------------+------------------+----------------------+
| 81.2.69.0/24 |            1 |                1 |                   1 |               1 |                1 |                    1 |
+--------------+--------------+------------------+---------------------+-----------------+------------------+----------------------+
```

#### GeoIP-Anonymous-Plus-CSV (`maxmind_anonymous_plus`):

```text
maxmind_anonymous_plus> CALL find_network_by_ip('81.2.69.142');
+--------------+--------------+------------------+---------------------+-----------------+------------------+----------------------+---------------+-----------------------+-------------------+
| network      | is_anonymous | is_anonymous_vpn | is_hosting_provider | is_public_proxy | is_tor_exit_node | is_residential_proxy | provider_name | anonymizer_confidence | network_last_seen |
+--------------+--------------+------------------+---------------------+-----------------+------------------+----------------------+---------------+-----------------------+-------------------+
| 81.2.69.0/24 |            1 |                1 |                   1 |               1 |                1 |                    1 | NULL          |                  NULL | NULL              |
+--------------+--------------+------------------+---------------------+-----------------+------------------+----------------------+---------------+-----------------------+-------------------+
```

#### GeoLite2-ASN-CSV (`maxmind_asn`):

```text
maxmind_asn> CALL find_network_by_ip('1.0.0.0');
+------------+--------------------------+--------------------------------+
| network    | autonomous_system_number | autonomous_system_organization |
+------------+--------------------------+--------------------------------+
| 1.0.0.0/24 |                    15169 | Google Inc.                    |
+------------+--------------------------+--------------------------------+
```

Location database examples use the same helper set across GeoIP2, GeoLite2,
and Enterprise schemas.

#### GeoIP2-City-CSV (`maxmind_geoip2_city`):

```text
maxmind_geoip2_city> SELECT find_geoname_id_by_ip('81.2.69.142') AS geoname_id;
+------------+
| geoname_id |
+------------+
|    2643743 |
+------------+
```

```text
maxmind_geoip2_city> CALL find_geoinfo_by_ip('81.2.69.142');
+------------------+--------------------------------------------+------------------------------------------------------------+-------------------------------------------+---------------------------------------------+---------------------------------------------+-----------------------------------------------+---------------------------------------------+-----------------+----------------------------------------------------------------------+
| country_iso_code | location_en                                | location_ru                                                | location_de                               | location_es                                 | location_fr                                 | location_ja                                   | location_pt_br                              | location_zh_cn  | location_mix                                                         |
+------------------+--------------------------------------------+------------------------------------------------------------+-------------------------------------------+---------------------------------------------+---------------------------------------------+-----------------------------------------------+---------------------------------------------+-----------------+----------------------------------------------------------------------+
| GB               | Europe - United Kingdom - England - London | Европа - Великобритания - Лондон                           | Europa - Vereinigtes Königreich - London  | Europa - Reino Unido - Inglaterra - Londres | Europe - Royaume-Uni - Angleterre - Londres | ヨーロッパ - イギリス - ロンドン              | Europa - Reino Unido - Inglaterra - Londres | 欧洲 - 英国     | Европа - Великобритания - England - Лондон                           |
+------------------+--------------------------------------------+------------------------------------------------------------+-------------------------------------------+---------------------------------------------+---------------------------------------------+-----------------------------------------------+---------------------------------------------+-----------------+----------------------------------------------------------------------+
```

```text
maxmind_geoip2_city> SELECT build_location_mix(find_geoname_id_by_ip('81.2.69.142'), 1) AS location_mix;
+-----------------------------------------------+
| location_mix                                  |
+-----------------------------------------------+
| Европа - 🇬🇧 Великобритания - England - Лондон |
+-----------------------------------------------+
```

```text
maxmind_geoip2_city> SELECT build_location_mix_with_iso_code(find_geoname_id_by_ip('81.2.69.142')) AS location_mix_iso;
+-------------------------------------------------+
| location_mix_iso                                |
+-------------------------------------------------+
| Европа - [GB] Великобритания - England - Лондон |
+-------------------------------------------------+
```

#### GeoLite2-City-CSV (`maxmind_geolite2_city`):

```text
maxmind_geolite2_city> SELECT find_geoname_id_by_ip('81.2.69.142') AS geoname_id;
+------------+
| geoname_id |
+------------+
|    2650444 |
+------------+
```

```text
maxmind_geolite2_city> CALL find_geoinfo_by_ip('81.2.69.142');
+------------------+------------------------------------------------------------+----------------------------------------------------------------------+--------------------------------------------------+---------------------------------------------------+------------------------------------------------------------+-----------------------------------------------------------------------------------+-----------------------------------+-----------------------------+-------------------------------------------------------------------------------+
| country_iso_code | location_en                                                | location_ru                                                          | location_de                                      | location_es                                       | location_fr                                                | location_ja                                                                       | location_pt_br                    | location_zh_cn              | location_mix                                                                  |
+------------------+------------------------------------------------------------+----------------------------------------------------------------------+--------------------------------------------------+---------------------------------------------------+------------------------------------------------------------+-----------------------------------------------------------------------------------+-----------------------------------+-----------------------------+-------------------------------------------------------------------------------+
| GB               | Europe - United Kingdom - England - Barnet - East Finchley | Европа - Британия - Англия - Ист-Финчли                              | Europa - UK - England - London Borough of Barnet | Europa - Reino Unido - Inglaterra - East Finchley | Europe - Royaume-Uni - Angleterre - Barnet - East Finchley | ヨーロッパ - 英国 - イングランド - イースト・フィンチリー                         | Europa - Reino Unido - Inglaterra | 欧洲 - 英国 - 英格兰        | Европа - Британия - Англия - Barnet - Ист-Финчли                              |
+------------------+------------------------------------------------------------+----------------------------------------------------------------------+--------------------------------------------------+---------------------------------------------------+------------------------------------------------------------+-----------------------------------------------------------------------------------+-----------------------------------+-----------------------------+-------------------------------------------------------------------------------+
```

```text
maxmind_geolite2_city> SELECT build_location_mix(find_geoname_id_by_ip('81.2.69.142'), 1) AS location_mix;
+-----------------------------------------------------+
| location_mix                                        |
+-----------------------------------------------------+
| Европа - 🇬🇧 Британия - Англия - Barnet - Ист-Финчли |
+-----------------------------------------------------+
```

```text
maxmind_geolite2_city> SELECT build_location_mix_with_iso_code(find_geoname_id_by_ip('81.2.69.142')) AS location_mix_iso;
+-------------------------------------------------------+
| location_mix_iso                                      |
+-------------------------------------------------------+
| Европа - [GB] Британия - Англия - Barnet - Ист-Финчли |
+-------------------------------------------------------+
```

Every generated MySQL schema also has `inet6_aton_decimal(ip)`, an internal
helper used by lookup routines. It is useful for ad hoc IPv6 range lookups:

```sql
USE maxmind_geolite2_city;

SELECT
  network,
  start_ip,
  last_ip,
  v_geoname_id,
  geoname_id,
  registered_country_geoname_id,
  represented_country_geoname_id,
  is_anonymous_proxy,
  is_satellite_provider,
  postal_code,
  latitude,
  longitude,
  accuracy_radius,
  is_anycast
FROM (
  SELECT *
  FROM ipv6
  WHERE start_ip <= inet6_aton_decimal('2001:218::')
  ORDER BY start_ip DESC
  LIMIT 1
) AS candidate
WHERE candidate.last_ip >= inet6_aton_decimal('2001:218::');
```

```text
+---------------+----------------------------------------+----------------------------------------+--------------+------------+-------------------------------+--------------------------------+--------------------+-----------------------+-------------+----------+-----------+-----------------+------------+
| network       | start_ip                               | last_ip                                | v_geoname_id | geoname_id | registered_country_geoname_id | represented_country_geoname_id | is_anonymous_proxy | is_satellite_provider | postal_code | latitude | longitude | accuracy_radius | is_anycast |
+---------------+----------------------------------------+----------------------------------------+--------------+------------+-------------------------------+--------------------------------+--------------------+-----------------------+-------------+----------+-----------+-----------------+------------+
| 2001:218::/35 | 42540530628270950406235306564857626624 | 42540530638174470720518348764050620415 |      1861060 |    1861060 |                       1861060 |                           NULL |                  0 |                     0 | NULL        |  35.6900 |  139.6900 |             500 |       NULL |
+---------------+----------------------------------------+----------------------------------------+--------------+------------+-------------------------------+--------------------------------+--------------------+-----------------------+-------------+----------+-----------+-----------------+------------+
```

#### GeoIP2-Connection-Type-CSV (`maxmind_connection_type`):

```text
maxmind_connection_type> CALL find_network_by_ip('1.0.0.0');
+------------+-----------------+
| network    | connection_type |
+------------+-----------------+
| 1.0.0.0/24 | Cable/DSL       |
+------------+-----------------+
```

#### GeoIP2-Country-CSV (`maxmind_geoip2_country`):

```text
maxmind_geoip2_country> SELECT find_geoname_id_by_ip('81.2.69.142') AS geoname_id;
+------------+
| geoname_id |
+------------+
|    2635167 |
+------------+
```

```text
maxmind_geoip2_country> CALL find_geoinfo_by_ip('81.2.69.142');
+------------------+-------------------------+---------------------------------------------+----------------------------------+----------------------+----------------------+--------------------------------+----------------------+-----------------+---------------------------------------------+
| country_iso_code | location_en             | location_ru                                 | location_de                      | location_es          | location_fr          | location_ja                    | location_pt_br       | location_zh_cn  | location_mix                                |
+------------------+-------------------------+---------------------------------------------+----------------------------------+----------------------+----------------------+--------------------------------+----------------------+-----------------+---------------------------------------------+
| GB               | Europe - United Kingdom | Европа - Великобритания                     | Europa - Vereinigtes Königreich  | Europa - Reino Unido | Europe - Royaume-Uni | ヨーロッパ - イギリス          | Europa - Reino Unido | 欧洲 - 英国     | Европа - Великобритания                     |
+------------------+-------------------------+---------------------------------------------+----------------------------------+----------------------+----------------------+--------------------------------+----------------------+-----------------+---------------------------------------------+
```

```text
maxmind_geoip2_country> SELECT build_location_mix(find_geoname_id_by_ip('81.2.69.142'), 1) AS location_mix;
+----------------------------+
| location_mix               |
+----------------------------+
| Европа - 🇬🇧 Великобритания |
+----------------------------+
```

```text
maxmind_geoip2_country> SELECT build_location_mix_with_iso_code(find_geoname_id_by_ip('81.2.69.142')) AS location_mix_iso;
+------------------------------+
| location_mix_iso             |
+------------------------------+
| Европа - [GB] Великобритания |
+------------------------------+
```

#### GeoLite2-Country-CSV (`maxmind_geolite2_country`):

```text
maxmind_geolite2_country> SELECT find_geoname_id_by_ip('81.2.69.142') AS geoname_id;
+------------+
| geoname_id |
+------------+
|    2635167 |
+------------+
```

```text
maxmind_geolite2_country> CALL find_geoinfo_by_ip('81.2.69.142');
+------------------+-------------------------+---------------------------------+-------------+----------------------+----------------------+--------------------------+----------------------+-----------------+---------------------------------+
| country_iso_code | location_en             | location_ru                     | location_de | location_es          | location_fr          | location_ja              | location_pt_br       | location_zh_cn  | location_mix                    |
+------------------+-------------------------+---------------------------------+-------------+----------------------+----------------------+--------------------------+----------------------+-----------------+---------------------------------+
| GB               | Europe - United Kingdom | Европа - Британия               | Europa - UK | Europa - Reino Unido | Europe - Royaume-Uni | ヨーロッパ - 英国        | Europa - Reino Unido | 欧洲 - 英国     | Европа - Британия               |
+------------------+-------------------------+---------------------------------+-------------+----------------------+----------------------+--------------------------+----------------------+-----------------+---------------------------------+
```

```text
maxmind_geolite2_country> SELECT build_location_mix(find_geoname_id_by_ip('81.2.69.142'), 1) AS location_mix;
+----------------------+
| location_mix         |
+----------------------+
| Европа - 🇬🇧 Британия |
+----------------------+
```

```text
maxmind_geolite2_country> SELECT build_location_mix_with_iso_code(find_geoname_id_by_ip('81.2.69.142')) AS location_mix_iso;
+------------------------+
| location_mix_iso       |
+------------------------+
| Европа - [GB] Британия |
+------------------------+
```

#### GeoIP2-Domain-CSV (`maxmind_domain`):

```text
maxmind_domain> CALL find_network_by_ip('81.2.69.142');
+--------------+--------------+
| network      | domain       |
+--------------+--------------+
| 81.2.64.0/19 | in-addr.arpa |
+--------------+--------------+
```

#### GeoIP2-Enterprise-CSV (`maxmind_enterprise`):

```text
maxmind_enterprise> SELECT find_geoname_id_by_ip('81.2.69.170') AS geoname_id;
+------------+
| geoname_id |
+------------+
|    2643743 |
+------------+
```

```text
maxmind_enterprise> CALL find_geoinfo_by_ip('81.2.69.170');
+------------------+--------------------------------------------+------------------------------------------------------------+-------------------------------------------+---------------------------------------------+---------------------------------------------+-----------------------------------------------+---------------------------------------------+-----------------+----------------------------------------------------------------------+
| country_iso_code | location_en                                | location_ru                                                | location_de                               | location_es                                 | location_fr                                 | location_ja                                   | location_pt_br                              | location_zh_cn  | location_mix                                                         |
+------------------+--------------------------------------------+------------------------------------------------------------+-------------------------------------------+---------------------------------------------+---------------------------------------------+-----------------------------------------------+---------------------------------------------+-----------------+----------------------------------------------------------------------+
| GB               | Europe - United Kingdom - England - London | Европа - Великобритания - Лондон                           | Europa - Vereinigtes Königreich - London  | Europa - Reino Unido - Inglaterra - Londres | Europe - Royaume-Uni - Angleterre - Londres | ヨーロッパ - イギリス - ロンドン              | Europa - Reino Unido - Inglaterra - Londres | 欧洲 - 英国     | Европа - Великобритания - England - Лондон                           |
+------------------+--------------------------------------------+------------------------------------------------------------+-------------------------------------------+---------------------------------------------+---------------------------------------------+-----------------------------------------------+---------------------------------------------+-----------------+----------------------------------------------------------------------+
```

```text
maxmind_enterprise> SELECT build_location_mix(find_geoname_id_by_ip('81.2.69.170'), 1) AS location_mix;
+-----------------------------------------------+
| location_mix                                  |
+-----------------------------------------------+
| Европа - 🇬🇧 Великобритания - England - Лондон |
+-----------------------------------------------+
```

```text
maxmind_enterprise> SELECT build_location_mix_with_iso_code(find_geoname_id_by_ip('81.2.69.170')) AS location_mix_iso;
+-------------------------------------------------+
| location_mix_iso                                |
+-------------------------------------------------+
| Европа - [GB] Великобритания - England - Лондон |
+-------------------------------------------------+
```

Enterprise also creates the `isp` table and adds Enterprise-specific columns to
`ipv4`/`ipv6`. Use a direct range lookup when those columns are needed. The
generated range index is on `(start_ip DESC, last_ip)`, so the query first
finds the nearest candidate by `start_ip`, then verifies `last_ip`.

```sql
USE maxmind_enterprise;

SELECT
  b.network,
  b.start_ip,
  b.last_ip,
  b.v_geoname_id,
  b.geoname_id,
  b.registered_country_geoname_id,
  b.represented_country_geoname_id,
  b.is_anonymous_proxy,
  b.is_satellite_provider,
  b.postal_code,
  b.latitude,
  b.longitude,
  b.isp_id,
  b.is_legitimate_proxy,
  b.domain,
  b.accuracy_radius,
  b.country_confidence,
  b.subdivision_confidence,
  b.city_confidence,
  b.postal_confidence,
  b.is_anycast,
  i.isp_id AS isp_isp_id,
  i.isp,
  i.organization,
  i.autonomous_system_number,
  i.autonomous_system_organization,
  i.connection_type,
  i.user_type,
  i.mobile_country_code,
  i.mobile_network_code
FROM (
  SELECT *
  FROM ipv4
  WHERE start_ip <= INET_ATON('81.2.69.170')
  ORDER BY start_ip DESC
  LIMIT 1
) AS b
LEFT JOIN isp AS i ON i.isp_id = b.isp_id
WHERE b.last_ip >= INET_ATON('81.2.69.170');
```

```text
+----------------+------------+------------+--------------+------------+-------------------------------+--------------------------------+--------------------+-----------------------+-------------+----------+-----------+--------+---------------------+--------------+-----------------+--------------------+------------------------+-----------------+-------------------+------------+------------+----------------------+---------------------------+--------------------------+--------------------------------+-----------------+------------+---------------------+---------------------+
| network        | start_ip   | last_ip    | v_geoname_id | geoname_id | registered_country_geoname_id | represented_country_geoname_id | is_anonymous_proxy | is_satellite_provider | postal_code | latitude | longitude | isp_id | is_legitimate_proxy | domain       | accuracy_radius | country_confidence | subdivision_confidence | city_confidence | postal_confidence | is_anycast | isp_isp_id | isp                  | organization              | autonomous_system_number | autonomous_system_organization | connection_type | user_type  | mobile_country_code | mobile_network_code |
+----------------+------------+------------+--------------+------------+-------------------------------+--------------------------------+--------------------+-----------------------+-------------+----------+-----------+--------+---------------------+--------------+-----------------+--------------------+------------------------+-----------------+-------------------+------------+------------+----------------------+---------------------------+--------------------------+--------------------------------+-----------------+------------+---------------------+---------------------+
| 81.2.69.160/27 | 1359103392 | 1359103423 |      2643743 |    2643743 |                       6252001 |                           NULL |                  0 |                     0 | NULL        |  51.5142 |   -0.0931 |      3 |                NULL | in-addr.arpa |             100 |            99.0000 |                42.0000 |         42.0000 |              NULL |       NULL |          3 | Andrews & Arnold Ltd | STONEHOUSE office network |                     NULL | NULL                           | Corporate       | government | NULL                | NULL                |
+----------------+------------+------------+--------------+------------+-------------------------------+--------------------------------+--------------------+-----------------------+-------------+----------+-----------+--------+---------------------+--------------+-----------------+--------------------+------------------------+-----------------+-------------------+------------+------------+----------------------+---------------------------+--------------------------+--------------------------------+-----------------+------------+---------------------+---------------------+
```

#### GeoIP2-IP-Risk-CSV (`maxmind_ip_risk`):

```text
maxmind_ip_risk> CALL find_network_by_ip('214.2.3.0');
+--------------+---------+--------------+------------------+---------------------+-----------------+------------------+----------------------+---------------+-----------------------+-------------------+
| network      | ip_risk | is_anonymous | is_anonymous_vpn | is_hosting_provider | is_public_proxy | is_tor_exit_node | is_residential_proxy | provider_name | anonymizer_confidence | network_last_seen |
+--------------+---------+--------------+------------------+---------------------+-----------------+------------------+----------------------+---------------+-----------------------+-------------------+
| 214.2.3.0/30 | 25.0000 |            1 |                1 |                NULL |            NULL |             NULL |                 NULL | NULL          |                  NULL | NULL              |
+--------------+---------+--------------+------------------+---------------------+-----------------+------------------+----------------------+---------------+-----------------------+-------------------+
```

#### GeoIP2-ISP-CSV (`maxmind_isp`):

```text
maxmind_isp> CALL find_network_by_ip('1.0.128.0');
+--------------+----------------------------+----------------------------+--------------------------+--------------------------------+---------------------+---------------------+
| network      | isp                        | organization               | autonomous_system_number | autonomous_system_organization | mobile_country_code | mobile_network_code |
+--------------+----------------------------+----------------------------+--------------------------+--------------------------------+---------------------+---------------------+
| 1.0.128.0/17 | TOT Public Company Limited | TOT Public Company Limited |                     NULL | NULL                           | NULL                | NULL                |
+--------------+----------------------------+----------------------------+--------------------------+--------------------------------+---------------------+---------------------+
```

#### GeoIP-Residential-Proxy-CSV (`maxmind_residential_proxy`):

```text
maxmind_residential_proxy> CALL find_network_by_ip('6.0.42.17');
+--------------+---------------+-----------------------+-------------------+
| network      | provider_name | anonymizer_confidence | network_last_seen |
+--------------+---------------+-----------------------+-------------------+
| 6.0.42.17/32 | novada        |                    95 | 2026-05-14        |
+--------------+---------------+-----------------------+-------------------+
```

#### GeoIP2-Static-IP-Score-CSV (`maxmind_static_ip_score`):

```text
maxmind_static_ip_score> CALL find_network_by_ip('81.2.69.142');
+------------+--------+
| network    | score  |
+------------+--------+
| 80.0.0.0/4 | 0.3400 |
+------------+--------+
```

#### GeoIP2-User-Count-CSV (`maxmind_user_count`):

```text
maxmind_user_count> CALL find_network_by_ip('81.2.69.142');
+------------+---------+---------+
| network    | ipv4_24 | ipv4_32 |
+------------+---------+---------+
| 80.0.0.0/4 |       0 |       0 |
+------------+---------+---------+
```

```text
maxmind_user_count> CALL find_network_by_ip('::2:0:0:0');
+--------------+---------+---------+---------+
| network      | ipv6_32 | ipv6_48 | ipv6_64 |
+--------------+---------+---------+---------+
| ::2:0:0:0/79 |       0 |       0 |       0 |
+--------------+---------+---------+---------+
```

```text
maxmind_user_count> CALL find_networks_by_ips_json('["81.2.69.142","::2:0:0:0"]');
+-----+-------------+--------------+---------+---------+---------+---------+---------+
| ord | ip          | network      | ipv4_24 | ipv4_32 | ipv6_32 | ipv6_48 | ipv6_64 |
+-----+-------------+--------------+---------+---------+---------+---------+---------+
|   1 | 81.2.69.142 | 80.0.0.0/4   |       0 |       0 |    NULL |    NULL |    NULL |
|   2 | ::2:0:0:0   | ::2:0:0:0/79 |    NULL |    NULL |       0 |       0 |       0 |
+-----+-------------+--------------+---------+---------+---------+---------+---------+
```

PostgreSQL examples from the bundled test data loaded into PostgreSQL:

```sql
SELECT * FROM maxmind_anonymous_ip.find_network_by_ip('81.2.69.142');
SELECT * FROM maxmind_anonymous_plus.find_network_by_ip('81.2.69.142');
SELECT * FROM maxmind_asn.find_network_by_ip('1.0.0.0');
SELECT * FROM maxmind_geoip2_city.find_geoinfo_by_ip('81.2.69.142');
SELECT * FROM maxmind_geolite2_city.find_geoinfo_by_ip('81.2.69.142');
SELECT * FROM maxmind_connection_type.find_network_by_ip('1.0.0.0');
SELECT * FROM maxmind_geoip2_country.find_geoinfo_by_ip('81.2.69.142');
SELECT * FROM maxmind_geolite2_country.find_geoinfo_by_ip('81.2.69.142');
SELECT * FROM maxmind_domain.find_network_by_ip('81.2.69.142');
SELECT * FROM maxmind_enterprise.find_geoinfo_by_ip('81.2.69.170');
SELECT * FROM maxmind_ip_risk.find_network_by_ip('214.2.3.0');
SELECT * FROM maxmind_isp.find_network_by_ip('1.0.128.0');
SELECT * FROM maxmind_residential_proxy.find_network_by_ip('6.0.42.17');
SELECT * FROM maxmind_static_ip_score.find_network_by_ip('81.2.69.142');
SELECT * FROM maxmind_user_count.find_network_by_ip('81.2.69.142');
SELECT * FROM maxmind_user_count.find_ipv4_network_by_ip('81.2.69.142');
SELECT * FROM maxmind_user_count.find_ipv6_network_by_ip('::2:0:0:0');
SELECT * FROM maxmind_user_count.find_ipv4_networks_by_ips_json(
  '["81.2.69.142","89.160.20.112"]'::jsonb
);
SELECT * FROM maxmind_user_count.find_ipv6_networks_by_ips_json(
  '["::2:0:0:0"]'::jsonb
);
```

For MySQL, enable local infile support for imports. The generated loader passes
`--local-infile=1`.

## Tests

Example ZIP archives live in `test/data/`. The test configs use paths relative
to the `test/` directory, such as `data/GeoIP2-Domain-CSV_Example.zip`.

`test/count-data.sh` counts rows directly from the source ZIP archives. It is
useful for checking generated database row counts after an import:

```bash
./test/count-data.sh
./test/count-data.sh GeoIP2-Connection-Type-CSV_Example.zip
```

After loading the test SQL into MySQL or PostgreSQL, run
`test/select-counts.sql` against the database and compare the results with
`count-data.sh`. The SQL covers all schemas used by the current test configs,
including network-only schemas, City/Country, and Enterprise.
