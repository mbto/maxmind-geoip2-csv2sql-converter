#!/usr/bin/env python3
"""Build, import, rebuild, validate, and optionally drop generated test schemas."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path


IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def read_ini(path: Path) -> dict[str, dict[str, str]]:
    sections: dict[str, dict[str, str]] = {}
    section = ""
    for raw_line in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw_line.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            sections.setdefault(section, {})
            continue
        if section and "=" in line:
            key, value = line.split("=", 1)
            sections[section][key.strip()] = value.strip()
    return sections


def required(mapping: dict[str, str], key: str) -> str:
    value = mapping.get(key, "")
    if not value:
        raise RuntimeError(f"missing required setting: {key}")
    return value


def to_msys_path(path: Path) -> str:
    resolved = path.resolve()
    drive = resolved.drive
    if not drive or len(drive) < 1:
        return resolved.as_posix()
    tail = resolved.as_posix()[len(drive):].lstrip("/")
    return f"/{drive[0].lower()}/{tail}"


def bash_login_command(bash: str, directory: Path, executable: str, *arguments: str) -> list[str]:
    command = " ".join((
        "cd --",
        shlex.quote(to_msys_path(directory)),
        "&& exec",
        shlex.quote(executable),
        *(shlex.quote(argument) for argument in arguments),
    ))
    return [bash, "-lc", command]


def write_log(path: Path, result: subprocess.CompletedProcess[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        f"exit_code={result.returncode}\n\nSTDOUT\n{result.stdout}\n\nSTDERR\n{result.stderr}\n",
        encoding="utf-8",
    )


def run_logged(command: list[str], log_path: Path, timeout: int) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
        check=False,
    )
    write_log(log_path, result)
    if result.returncode:
        detail = (result.stderr.strip() or result.stdout.strip())[-3000:]
        raise RuntimeError(f"command failed ({result.returncode}); see {log_path}\n{detail}")
    return result


def db_command(
    dbms: str,
    settings: dict[str, str],
    sql: str,
    headers: bool = False,
) -> tuple[list[str], dict[str, str]]:
    environment = os.environ.copy()
    if dbms == "mysql":
        environment["MYSQL_PWD"] = settings.get("mysql_password", "")
        command = [
            required(settings, "mysql_command"),
            f"--host={required(settings, 'mysql_host')}",
            f"--port={required(settings, 'mysql_port')}",
            f"--user={required(settings, 'mysql_user')}",
            "--batch",
            "--raw",
            "--default-character-set=utf8mb4",
        ]
        if not headers:
            command.append("--skip-column-names")
        command.extend(("--execute", sql))
        return command, environment
    environment["PGPASSWORD"] = settings.get("postgresql_password", "")
    command = [
        required(settings, "postgresql_command"),
        "-X",
        f"--host={required(settings, 'postgresql_host')}",
        f"--port={required(settings, 'postgresql_port')}",
        f"--username={required(settings, 'postgresql_user')}",
        f"--dbname={required(settings, 'postgresql_database')}",
        "--set=ON_ERROR_STOP=1",
        "--csv",
        "--quiet",
    ]
    if not headers:
        command.append("--tuples-only")
    command.extend(("--command", sql))
    return command, environment


def query(
    dbms: str,
    settings: dict[str, str],
    sql: str,
    headers: bool = False,
) -> list[list[str]]:
    command, environment = db_command(dbms, settings, sql, headers=headers)
    result = subprocess.run(
        command,
        env=environment,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=60,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    if dbms == "mysql":
        return [line.split("\t") for line in result.stdout.splitlines() if line]
    return list(csv.reader(result.stdout.splitlines()))


def require_single_row(
    rows: list[list[str]],
    context: str,
    expected_columns: int,
) -> list[str]:
    if len(rows) != 1:
        raise RuntimeError(
            f"{context}: expected exactly one result row, got {len(rows)}; rows={rows!r}"
        )
    row = rows[0]
    if len(row) != expected_columns:
        raise RuntimeError(
            f"{context}: expected {expected_columns} result columns, "
            f"got {len(row)}; row={row!r}"
        )
    return row


def sql_identifier(dbms: str, value: str) -> str:
    if not IDENTIFIER_RE.fullmatch(value):
        raise RuntimeError(f"unsafe SQL identifier: {value!r}")
    return f"`{value}`" if dbms == "mysql" else f'"{value}"'


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def validate_schema(
    dbms: str,
    sections: dict[str, dict[str, str]],
    edition: str,
    schema: str,
) -> dict[str, object]:
    settings = sections["settings"]
    schema_literal = sql_string(schema)
    column_rows = query(
        dbms,
        settings,
        "SELECT table_name,column_name FROM information_schema.columns "
        f"WHERE table_schema={schema_literal} ORDER BY table_name,ordinal_position",
    )
    columns: dict[str, set[str]] = {}
    for table, column in column_rows:
        columns.setdefault(table, set()).add(column)

    convert = sections[f"{edition}.convert"]
    ip_versions = {item.strip() for item in convert.get("ip_versions", "4,6").split(",") if item.strip()}
    failures: list[str] = []
    counts: dict[str, int] = {}
    configured_network_columns: dict[str, bool] = {}
    qualified_schema = sql_identifier(dbms, schema)

    for version in ("4", "6"):
        table = f"ipv{version}"
        expected_table = version in ip_versions
        actual_table = table in columns
        if expected_table != actual_table:
            failures.append(f"{table}: expected table={expected_table}, actual={actual_table}")
            continue
        if not expected_table:
            continue

        configured_columns = sections.get(f"{edition}.columns.{table}", {})
        for column, configured_value in configured_columns.items():
            if configured_value.lower() not in {"true", "false"}:
                continue
            expected_column = configured_value.lower() == "true"
            configured_network_columns[column] = (
                configured_network_columns.get(column, False) or expected_column
            )
            actual_column = column in columns[table]
            if expected_column != actual_column:
                failures.append(
                    f"{table}.{column}: expected column={expected_column}, actual={actual_column}"
                )

        count_rows = query(
            dbms,
            settings,
            f"SELECT COUNT(*) FROM {qualified_schema}.{sql_identifier(dbms, table)}",
        )
        count_value = require_single_row(
            count_rows,
            f"{schema}.{table} row count",
            1,
        )[0]
        try:
            row_count = int(count_value)
        except ValueError as error:
            raise RuntimeError(
                f"{schema}.{table} row count: expected an integer, got {count_value!r}"
            ) from error
        counts[table] = row_count
        if row_count <= 0:
            failures.append(f"{table}: no imported rows")

    if dbms == "mysql":
        network_sql = (
            f"CALL {qualified_schema}.{sql_identifier(dbms, 'find_network_by_ip')}('1.0.0.1')"
        )
        batch_sql = (
            f"CALL {qualified_schema}.{sql_identifier(dbms, 'find_networks_by_json_ips')}("
            "JSON_ARRAY('1.0.0.1','2001:4860:4860::8888'),1,40)"
        )
    else:
        network_sql = (
            f"SELECT * FROM {qualified_schema}.{sql_identifier(dbms, 'find_network_by_ip')}("
            "'1.0.0.1') LIMIT 0"
        )
        batch_sql = (
            f"SELECT * FROM {qualified_schema}.{sql_identifier(dbms, 'find_networks_by_json_ips')}("
            "'[\"1.0.0.1\",\"2001:4860:4860::8888\"]'::jsonb,1,40) LIMIT 0"
        )
    api_columns: dict[str, set[str]] = {}
    for routine_name, sql in (
        ("find_network_by_ip", network_sql),
        ("find_networks_by_json_ips", batch_sql),
    ):
        rows = query(dbms, settings, sql, headers=True)
        if not rows:
            failures.append(f"{routine_name}: client returned no result header")
            continue
        api_columns[routine_name] = set(rows[0])
        for column, expected_column in configured_network_columns.items():
            actual_column = column in api_columns[routine_name]
            if expected_column != actual_column:
                failures.append(
                    f"{routine_name}.{column}: expected result column={expected_column}, "
                    f"actual={actual_column}"
                )

    metadata_rows = query(
        dbms,
        settings,
        f"SELECT COUNT(*),MIN(schema_version),MAX(schema_version),MIN(edition_id) "
        f"FROM {qualified_schema}.{sql_identifier(dbms, 'dataset_metadata')}",
    )
    metadata_count, min_version, max_version, metadata_edition = require_single_row(
        metadata_rows,
        f"{schema}.dataset_metadata aggregate",
        4,
    )
    if metadata_count != "1":
        failures.append(f"dataset_metadata: expected 1 row, actual={metadata_count}")
    if min_version != "4" or max_version != "4":
        failures.append(f"dataset_metadata: expected schema_version=4, actual={min_version}/{max_version}")
    if metadata_edition != edition:
        failures.append(f"dataset_metadata: expected edition_id={edition}, actual={metadata_edition}")

    leftovers = query(
        dbms,
        settings,
        "SELECT COUNT(*) FROM information_schema.tables "
        f"WHERE table_schema={schema_literal} AND POSITION('__load_' IN table_name) > 0",
    )
    leftover_count = require_single_row(
        leftovers,
        f"{schema} staging table count",
        1,
    )[0]
    if leftover_count != "0":
        failures.append(f"staging tables remain: {leftover_count}")

    if failures:
        raise RuntimeError("schema validation failed:\n" + "\n".join(failures))
    return {
        "ip_versions": sorted(ip_versions),
        "row_counts": counts,
        "column_count": len(column_rows),
        "api_column_counts": {name: len(values) for name, values in api_columns.items()},
    }


def drop_test_schema(dbms: str, settings: dict[str, str], schema: str) -> None:
    if not schema.startswith("mm_"):
        raise RuntimeError(f"refusing to drop non-test schema: {schema}")
    qualified = sql_identifier(dbms, schema)
    sql = f"DROP DATABASE IF EXISTS {qualified}" if dbms == "mysql" else f"DROP SCHEMA IF EXISTS {qualified} CASCADE"
    query(dbms, settings, sql)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dbms", action="append", choices=("mysql", "postgresql"))
    parser.add_argument("--scenario", action="append")
    parser.add_argument("--include-full", action="store_true")
    parser.add_argument("--drop-schemas", action="store_true")
    parser.add_argument("--bash", default="C:/msys64/usr/bin/bash.exe")
    parser.add_argument("--report", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    project_dir = Path(__file__).resolve().parent.parent
    test_dir = project_dir / "test"
    generated_dir = test_dir / "generated"
    manifest_path = generated_dir / "manifest.tsv"
    rows = list(csv.DictReader(manifest_path.open(encoding="utf-8"), delimiter="\t"))

    selected_dbms = set(args.dbms or ("mysql", "postgresql"))
    selected_scenarios = set(args.scenario or ())
    selected_rows = []
    for row in rows:
        if row["dbms"] not in selected_dbms:
            continue
        if row["scenario"] == "all-examples":
            continue
        if selected_scenarios and row["scenario"] not in selected_scenarios:
            continue
        if row["full_archives"] == "true" and not args.include_full:
            continue
        selected_rows.append(row)
    if not selected_rows:
        raise RuntimeError("no matrix scenarios selected")

    logs_dir = generated_dir / "logs"
    report_rows: list[dict[str, object]] = []
    started_all = time.monotonic()
    for index, row in enumerate(selected_rows, 1):
        scenario = row["scenario"]
        dbms = row["dbms"]
        config_path = generated_dir / row["config"]
        sections = read_ini(config_path)
        editions = [item for item in row["editions"].split(",") if item]
        if len(editions) != 1:
            raise RuntimeError(f"matrix validation expects one edition: {scenario}")
        edition = editions[0]
        schema = row["schema"]
        if not schema.startswith("mm_"):
            raise RuntimeError(f"matrix scenario must use an mm_ schema: {scenario} -> {schema}")

        print(f"[{index}/{len(selected_rows)}] {scenario} {dbms}: build", flush=True)
        started = time.monotonic()
        converter_command = bash_login_command(
            args.bash,
            project_dir,
            "./maxmind-csv2sql-converter.sh",
            "-c",
            to_msys_path(config_path),
        )
        run_logged(
            converter_command,
            logs_dir / f"{scenario}.{dbms}.build.log",
            timeout=1200,
        )

        project_name = config_path.name[: -len(f".{dbms}.ini")]
        output_setting = required(sections["settings"], "output_dir")
        output_dir = (config_path.parent / output_setting).resolve()
        loader_path = output_dir / f"{project_name}.{dbms}" / "loader.sh"
        if not loader_path.is_file():
            raise RuntimeError(f"generated loader not found: {loader_path}")

        loader_runs = 2 if row["repeat_loader"] == "true" else 1
        for loader_run in range(1, loader_runs + 1):
            print(
                f"[{index}/{len(selected_rows)}] {scenario} {dbms}: import {loader_run}/{loader_runs}",
                flush=True,
            )
            run_logged(
                bash_login_command(args.bash, loader_path.parent, "./loader.sh"),
                logs_dir / f"{scenario}.{dbms}.import-{loader_run}.log",
                timeout=1200,
            )

        print(f"[{index}/{len(selected_rows)}] {scenario} {dbms}: validate", flush=True)
        validation = validate_schema(dbms, sections, edition, schema)
        routine_report = generated_dir / f"routine-smoke.{scenario}.{dbms}.json"
        run_logged(
            [
                sys.executable,
                str(test_dir / "run-routine-smoke.py"),
                "--dbms",
                dbms,
                "--config",
                str(config_path),
                "--schema",
                schema,
                "--report",
                str(routine_report),
            ],
            logs_dir / f"{scenario}.{dbms}.routines.log",
            timeout=600,
        )
        routine_summary = json.loads(routine_report.read_text(encoding="utf-8"))

        if args.drop_schemas:
            print(f"[{index}/{len(selected_rows)}] {scenario} {dbms}: drop {schema}", flush=True)
            drop_test_schema(dbms, sections["settings"], schema)

        report_rows.append({
            "scenario": scenario,
            "dbms": dbms,
            "edition": edition,
            "schema": schema,
            "loader_runs": loader_runs,
            "validation": validation,
            "routine_count": routine_summary["routine_count"],
            "routine_calls": routine_summary["call_count"],
            "seconds": round(time.monotonic() - started, 3),
        })
        print(f"[{index}/{len(selected_rows)}] {scenario} {dbms}: PASS", flush=True)

    report = {
        "scenario_count": len(report_rows),
        "seconds": round(time.monotonic() - started_all, 3),
        "results": report_rows,
    }
    report_path = args.report or generated_dir / "matrix-report.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"scenario_count": len(report_rows), "seconds": report["seconds"]}), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
