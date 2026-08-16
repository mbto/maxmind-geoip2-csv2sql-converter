#!/usr/bin/env python3
"""Call every generated routine in one or more imported test schemas."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


@dataclass(frozen=True)
class Routine:
    schema: str
    name: str
    kind: str
    parameters: tuple[str, ...]


def read_settings(path: Path) -> dict[str, str]:
    settings: dict[str, str] = {}
    section = ""
    for raw_line in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw_line.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            continue
        if section == "settings" and "=" in line:
            key, value = line.split("=", 1)
            settings[key.strip()] = value.strip()
    return settings


def required(settings: dict[str, str], key: str) -> str:
    value = settings.get(key, "")
    if not value:
        raise ValueError(f"settings.{key} is required")
    return value


class Client:
    def __init__(self, dbms: str, settings: dict[str, str]) -> None:
        self.dbms = dbms
        self.environment = os.environ.copy()
        if dbms == "mysql":
            self.command = required(settings, "mysql_command")
            self.base_args = [
                self.command,
                f"--host={required(settings, 'mysql_host')}",
                f"--port={required(settings, 'mysql_port')}",
                f"--user={required(settings, 'mysql_user')}",
                "--batch",
                "--raw",
                "--skip-column-names",
                "--default-character-set=utf8mb4",
            ]
            self.environment["MYSQL_PWD"] = settings.get("mysql_password", "")
        else:
            self.command = required(settings, "postgresql_command")
            self.base_args = [
                self.command,
                "-X",
                f"--host={required(settings, 'postgresql_host')}",
                f"--port={required(settings, 'postgresql_port')}",
                f"--username={required(settings, 'postgresql_user')}",
                f"--dbname={required(settings, 'postgresql_database')}",
                "--set=ON_ERROR_STOP=1",
                "--csv",
                "--tuples-only",
                "--quiet",
            ]
            self.environment["PGPASSWORD"] = settings.get("postgresql_password", "")

    def execute(self, sql: str, timeout: int = 30) -> subprocess.CompletedProcess[str]:
        option = "--execute" if self.dbms == "mysql" else "--command"
        return subprocess.run(
            [*self.base_args, option, sql],
            env=self.environment,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            check=False,
        )


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def schema_condition(schemas: list[str], column: str) -> str:
    if schemas:
        return f"{column} IN ({','.join(sql_string(schema) for schema in schemas)})"
    return f"(LEFT({column}, 8) = 'maxmind_' OR LEFT({column}, 3) = 'mm_')"


def discover_mysql(client: Client, schemas: list[str]) -> list[Routine]:
    query = f"""
SELECT r.ROUTINE_SCHEMA, r.ROUTINE_NAME, r.ROUTINE_TYPE,
       COALESCE(p.PARAMETER_NAME, ''), COALESCE(p.ORDINAL_POSITION, 0)
FROM information_schema.ROUTINES r
LEFT JOIN information_schema.PARAMETERS p
  ON p.SPECIFIC_SCHEMA = r.ROUTINE_SCHEMA
 AND p.SPECIFIC_NAME = r.SPECIFIC_NAME
WHERE {schema_condition(schemas, 'r.ROUTINE_SCHEMA')}
ORDER BY r.ROUTINE_SCHEMA, r.ROUTINE_NAME, p.ORDINAL_POSITION
"""
    result = client.execute(query)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())

    grouped: dict[tuple[str, str, str], list[tuple[int, str]]] = {}
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) != 5:
            raise RuntimeError(f"unexpected MySQL introspection row: {line!r}")
        schema, name, kind, parameter, ordinal_text = fields
        ordinal = int(ordinal_text)
        grouped.setdefault((schema, name, kind), [])
        if ordinal > 0 and parameter:
            grouped[(schema, name, kind)].append((ordinal, parameter))

    return [
        Routine(schema, name, kind, tuple(parameter for _, parameter in sorted(parameters)))
        for (schema, name, kind), parameters in sorted(grouped.items())
    ]


def split_pg_arguments(arguments: str) -> tuple[str, ...]:
    if not arguments.strip():
        return ()
    names: list[str] = []
    for argument in arguments.split(","):
        words = argument.strip().split()
        if len(words) < 2:
            raise RuntimeError(f"unexpected PostgreSQL argument: {argument!r}")
        names.append(words[0].strip('"'))
    return tuple(names)


def discover_postgresql(client: Client, schemas: list[str]) -> list[Routine]:
    query = f"""
SELECT n.nspname, p.proname, p.prokind,
       pg_get_function_identity_arguments(p.oid)
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE {schema_condition(schemas, 'n.nspname')}
ORDER BY n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)
"""
    result = client.execute(query)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())

    routines: list[Routine] = []
    for fields in csv.reader(result.stdout.splitlines()):
        if len(fields) != 4:
            raise RuntimeError(f"unexpected PostgreSQL introspection row: {fields!r}")
        schema, name, kind, arguments = fields
        routines.append(Routine(schema, name, kind, split_pg_arguments(arguments)))
    return routines


def ip_value(routine_name: str, variant: str | None = None) -> str:
    if variant == "ipv6" or "ipv6" in routine_name:
        return "2001:4860:4860::8888"
    return "1.0.0.1"


def parameter_value(dbms: str, routine_name: str, parameter: str, variant: str | None) -> str:
    name = parameter.lower()
    if "geoname_ids" in name:
        return "JSON_ARRAY(2643743,6252001,NULL)" if dbms == "mysql" else "'[2643743,6252001,null]'::jsonb"
    if name in {"ips_json", "p_ips"} or ("ips" in name and "geoname" not in name):
        return (
            "JSON_ARRAY('1.0.0.1','2001:4860:4860::8888','bad',NULL)"
            if dbms == "mysql"
            else "'[\"1.0.0.1\",\"2001:4860:4860::8888\",\"bad\",null]'::jsonb"
        )
    if "locales" in name:
        return "JSON_ARRAY('ru','en')" if dbms == "mysql" else "'[\"ru\",\"en\"]'::jsonb"
    if name in {"ip", "ip_param", "p_ip"}:
        return sql_string(ip_value(routine_name, variant))
    if "geoname_id" in name:
        return "2643743"
    if "locale" in name:
        return sql_string("ru")
    if name.startswith("include_"):
        return "1"
    if "per_page" in name:
        return "40"
    if name in {"page_param", "p_page", "page"} or name.endswith("_page"):
        return "1"
    raise ValueError(f"no smoke value for parameter {parameter!r}")


def invocation_variants(routine: Routine) -> tuple[str | None, ...]:
    has_single_ip = any(parameter.lower() in {"ip", "ip_param", "p_ip"} for parameter in routine.parameters)
    if has_single_ip and "ipv4" not in routine.name and "ipv6" not in routine.name:
        return ("ipv4", "ipv6")
    return (None,)


def quote_identifier(dbms: str, value: str) -> str:
    if dbms == "mysql":
        return "`" + value.replace("`", "``") + "`"
    return '"' + value.replace('"', '""') + '"'


def invocation_sql(dbms: str, routine: Routine, variant: str | None) -> str:
    arguments = ",".join(
        parameter_value(dbms, routine.name, parameter, variant)
        for parameter in routine.parameters
    )
    qualified_name = (
        f"{quote_identifier(dbms, routine.schema)}.{quote_identifier(dbms, routine.name)}"
    )
    if dbms == "mysql" and routine.kind.upper() == "PROCEDURE":
        return f"CALL {qualified_name}({arguments})"
    if dbms == "postgresql":
        return f"SELECT * FROM {qualified_name}({arguments}) LIMIT 1"
    return f"SELECT {qualified_name}({arguments})"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dbms", required=True, choices=("mysql", "postgresql"))
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--schema", action="append", default=[])
    parser.add_argument("--report", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    for schema in args.schema:
        if not IDENTIFIER_RE.fullmatch(schema):
            raise ValueError(f"invalid schema name: {schema!r}")

    settings = read_settings(args.config.resolve())
    client = Client(args.dbms, settings)
    routines = (
        discover_mysql(client, args.schema)
        if args.dbms == "mysql"
        else discover_postgresql(client, args.schema)
    )
    if not routines:
        raise RuntimeError("no generated routines found")

    failures: list[dict[str, str | int | None]] = []
    calls = 0
    for routine in routines:
        for variant in invocation_variants(routine):
            calls += 1
            try:
                sql = invocation_sql(args.dbms, routine, variant)
                result = client.execute(sql)
                if result.returncode:
                    failures.append({
                        "schema": routine.schema,
                        "routine": routine.name,
                        "variant": variant,
                        "returncode": result.returncode,
                        "error": (result.stderr.strip() or result.stdout.strip())[-2000:],
                    })
            except (ValueError, subprocess.TimeoutExpired) as error:
                failures.append({
                    "schema": routine.schema,
                    "routine": routine.name,
                    "variant": variant,
                    "returncode": -1,
                    "error": str(error),
                })

    report = {
        "dbms": args.dbms,
        "schemas": sorted({routine.schema for routine in routines}),
        "routine_count": len(routines),
        "call_count": calls,
        "failure_count": len(failures),
        "failures": failures,
    }
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in report.items() if key != "failures"}, ensure_ascii=False))
    for failure in failures:
        print(json.dumps(failure, ensure_ascii=False), file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
