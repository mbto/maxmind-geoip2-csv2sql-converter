# SQL Bash Generator Files

`default/functions.bash` is the full reference generator used by default configs.
Project-specific output schemas are normally configured in the main INI with
`[columns.<table>]` sections; copying this directory is only needed for custom
SQL behavior.

The main converter script sources exactly one `functions.bash` file. With
`convert.sql_bash_generator_file = functions.bash`, lookup is relative to the config
directory first:

```text
generators/<project_name>/functions.bash
```

when that file exists. Otherwise it falls back to the bundled default generator:

```text
generators/default/functions.bash
```

For an explicit custom generator, set `sql_bash_generator_file` to a relative or
absolute path to a `functions.bash` file.

A project functions file is regular Bash and must define these functions:

```text
write_00_create_raw
write_10_load_raw
write_20_transform_stage
write_90_indexes_stage
write_98_promote
write_99_routines
write_100_cleanup
write_load_data
write_loader
make_output_archive
```

The sourced generator can use variables and helper functions from
`maxmind-csv2sql-converter.sh`, including `RUN_DIR`, `CSV_DIR`, `DBMS`,
`SCHEMA_NAME`, `ARCHIVE_ROOT`, `ARCHIVE_EDITION_ID`, `ARCHIVE_EDITION_KIND`,
`ARCHIVE_LOCATION_KIND`, `ARCHIVE_FAMILY`, `ARCHIVE_BUILD_DATE`, `CSV_PREFIX`,
`SELECTED_LOCALES`, `LOAD_LOCALES`, `IP_VERSIONS`, `PRIORITY_FIELDS`, `ident`,
`mysql_ident`, `pg_ident`, `sql_literal`, `header_columns`, and `section_pairs`.
Arrays such as `SELECTED_LOCALES`, `LOAD_LOCALES`, `IP_VERSIONS`, and
`PRIORITY_FIELDS` are ordinary Bash variables available because the functions
file is sourced.

Meaning of the most commonly used values:

* `RUN_DIR` - generated package directory for the current project/dbms run, such as `converted/test.mysql`.
* `CSV_DIR` - archive-specific extracted CSV/TSV directory: `RUN_DIR/csv/ARCHIVE_ROOT`.
* `DBMS` - selected database type: `mysql` or `postgresql`.
* `SCHEMA_NAME` - target schema/database name from `[database].schema_name` or the selected edition-scoped override.
* `ARCHIVE_ROOT` - root directory name found inside the ZIP, such as `GeoIP2-City-CSV_Example`.
* `ARCHIVE_EDITION_ID` - edition id found in the ZIP root, such as `GeoIP2-City-CSV`.
* `ARCHIVE_EDITION_KIND` - MaxMind edition kind from the archive, such as `City`, `Country`, `Enterprise`, `Domain`, or `ASN`.
* `ARCHIVE_LOCATION_KIND` - location behavior kind. Enterprise uses `City` location semantics.
* `ARCHIVE_FAMILY` - `location` for City/Country/Enterprise archives, `network` for network-only archives.
* `ARCHIVE_BUILD_DATE` - archive build suffix from the ZIP root, either `YYYYMMDD` or `Example`.
* `CSV_PREFIX` - CSV filename prefix without the trailing `-CSV`, such as `GeoIP2-City`.
* `SELECTED_LOCALES` - locales requested by `[convert].locales`.
* `LOAD_LOCALES` - locales actually extracted for raw loading. It includes `en` even when `en` was not requested, because transforms use English rows as the base.
* `IP_VERSIONS` - IP block versions requested by `[convert].ip_versions`.
* `PRIORITY_FIELDS` - geoname id source columns requested by `[convert].v_geoname_id_priority_columns`.
* `ident` - quote an SQL identifier for the selected `DBMS`.
* `mysql_ident` - quote an SQL identifier using MySQL backtick rules.
* `pg_ident` - quote an SQL identifier using PostgreSQL double-quote rules.
* `sql_literal` - quote a string as an SQL literal.
* `header_columns` - print CSV header column names, one per line.
* `section_pairs` - print key/value pairs from an INI section, separated by a tab. It checks `[<edition>.<section>]` before `[<section>]`.

Generators should read extracted CSV files through `CSV_DIR`, never by joining
paths directly under `RUN_DIR`. Multiple editions in one config share one
`RUN_DIR`; MySQL and PostgreSQL configs use different directories because
`RUN_DIR` includes the database type. Each archive gets its own `CSV_DIR` under
`csv/<archive-root>` to prevent filename collisions.

Location filters are normal config pairs read with `section_pairs location_filters`.
The main script validates those keys against `*-Locations-en.csv` before the
generator is sourced. The default generator treats multiple values for one key
as OR and multiple keys as AND.
