#!/usr/bin/env python3
"""Generate integration-test INI files for the RAM-disk database instances."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path


ALL_EDITIONS = (
    "GeoIP2-Anonymous-IP-CSV",
    "GeoIP-Anonymous-Plus-CSV",
    "GeoLite2-ASN-CSV",
    "GeoIP2-City-CSV",
    "GeoLite2-City-CSV",
    "GeoIP2-Connection-Type-CSV",
    "GeoIP2-Country-CSV",
    "GeoLite2-Country-CSV",
    "GeoIP2-Domain-CSV",
    "GeoIP2-Enterprise-CSV",
    "GeoIP2-IP-Risk-CSV",
    "GeoIP2-ISP-CSV",
    "GeoIP-Residential-Proxy-CSV",
    "GeoIP2-Static-IP-Score-CSV",
    "GeoIP2-User-Count-CSV",
)

ARCHIVES = {
    "GeoIP2-Anonymous-IP-CSV": "GeoIP2-Anonymous-IP-CSV_Example.zip",
    "GeoIP-Anonymous-Plus-CSV": "GeoIP-Anonymous-Plus-CSV_Example.zip",
    "GeoLite2-ASN-CSV": "GeoLite2-ASN-CSV_Example.zip",
    "GeoIP2-City-CSV": "GeoIP2-City-CSV_Example.zip",
    "GeoLite2-City-CSV": "GeoLite2-City-CSV_Example.zip",
    "GeoIP2-Connection-Type-CSV": "GeoIP2-Connection-Type-CSV_Example.zip",
    "GeoIP2-Country-CSV": "GeoIP2-Country-CSV_Example.zip",
    "GeoLite2-Country-CSV": "GeoLite2-Country-CSV_Example.zip",
    "GeoIP2-Domain-CSV": "GeoIP2-Domain-CSV_Example.zip",
    "GeoIP2-Enterprise-CSV": "GeoIP2-Enterprise-CSV_Example.zip",
    "GeoIP2-IP-Risk-CSV": "GeoIP2-IP-Risk-CSV_Example.zip",
    "GeoIP2-ISP-CSV": "GeoIP2-ISP-CSV_Example.zip",
    "GeoIP-Residential-Proxy-CSV": "GeoIP-Residential-Proxy-CSV_Example.zip",
    "GeoIP2-Static-IP-Score-CSV": "GeoIP2-Static-IP-Score-CSV_Example.zip",
    "GeoIP2-User-Count-CSV": "GeoIP2-User-Count-CSV_Example.zip",
}

FULL_ARCHIVES = {
    "GeoLite2-City-CSV": "GeoLite2-City-CSV_20260605.zip",
    "GeoLite2-Country-CSV": "GeoLite2-Country-CSV_20260605.zip",
}

ALL_FILTERS = {
    "geoname_id": "[0-9]+",
    "continent_code": ".*",
    "continent_name": ".*",
    "country_iso_code": ".*",
    "country_name": ".*",
    "is_in_european_union": "0|1",
    "subdivision_1_iso_code": ".*",
    "subdivision_1_name": ".*",
    "subdivision_2_iso_code": ".*",
    "subdivision_2_name": ".*",
    "city_name": ".*",
    "metro_code": ".*",
    "time_zone": ".*",
}


@dataclass(frozen=True)
class Scenario:
    name: str
    editions: tuple[str, ...]
    profile: str = "all_true"
    ip_versions: str | None = None
    locales: str | None = None
    geo4: str = "111"
    geo6: str = "111"
    priority: str = "geoname_id,registered_country_geoname_id,represented_country_geoname_id"
    filters: dict[str, str] = field(default_factory=dict)
    column_overrides: dict[str, bool] = field(default_factory=dict)
    keep_default_schemas: bool = False
    full_archives: bool = False
    repeat_loader: bool = True


def geo_scenario(bits: str, index: int) -> Scenario:
    ip_values = ("4", "6", "4,6")
    locale_values = (
        "ru",
        "ja",
        "de,es",
        "fr",
        "pt-BR",
        "zh-CN",
        "ru,en",
        "en,ru,de,es,fr,ja,pt-BR,zh-CN",
    )
    priorities = (
        "represented_country_geoname_id,registered_country_geoname_id,geoname_id",
        "registered_country_geoname_id,geoname_id,represented_country_geoname_id",
        "geoname_id,represented_country_geoname_id,registered_country_geoname_id",
    )
    return Scenario(
        name=f"city-g{bits}",
        editions=("GeoIP2-City-CSV",),
        profile="all_false" if bits == "000" else ("all_true" if bits == "111" else "mixed"),
        ip_versions=ip_values[index % len(ip_values)],
        locales=locale_values[index],
        geo4=bits,
        geo6=bits,
        priority=priorities[index % len(priorities)],
        filters=ALL_FILTERS if bits == "111" else ({} if bits != "101" else {
            "country_iso_code": "GB",
            "city_name": "London|Boxford",
        }),
    )


SCENARIOS = [
    Scenario(
        name="all-examples",
        editions=ALL_EDITIONS,
        keep_default_schemas=True,
    ),
    *(geo_scenario(f"{value:03b}", value) for value in range(8)),
    Scenario(
        name="city-asymmetric",
        editions=("GeoIP2-City-CSV",),
        profile="mixed",
        ip_versions="4,6",
        locales="ja,zh-CN",
        geo4="100",
        geo6="011",
        priority="registered_country_geoname_id,represented_country_geoname_id,geoname_id",
    ),
    Scenario(
        name="country-false-v6",
        editions=("GeoIP2-Country-CSV",),
        profile="all_false",
        ip_versions="6",
        locales="zh-CN",
        geo4="000",
        geo6="000",
        filters={"continent_code": ".*", "country_iso_code": ".*"},
    ),
    Scenario(
        name="country-mixed-v4",
        editions=("GeoIP2-Country-CSV",),
        profile="mixed",
        ip_versions="4",
        locales="es,fr",
        geo4="101",
        filters={"country_name": ".*"},
    ),
    Scenario(
        name="enterprise-false-v4",
        editions=("GeoIP2-Enterprise-CSV",),
        profile="all_false",
        ip_versions="4",
        locales="ru",
        geo4="000",
        geo6="000",
    ),
    Scenario(
        name="enterprise-mixed-v6",
        editions=("GeoIP2-Enterprise-CSV",),
        profile="mixed",
        ip_versions="6",
        locales="fr,ja",
        geo6="101",
        filters={"continent_name": ".*", "time_zone": ".*"},
    ),
    Scenario(
        name="asn-false-v4",
        editions=("GeoLite2-ASN-CSV",),
        profile="all_false",
        ip_versions="4",
    ),
    Scenario(
        name="user-count-mixed",
        editions=("GeoIP2-User-Count-CSV",),
        profile="mixed",
        ip_versions="4,6",
        column_overrides={
            "ipv4.ipv4_24": True,
            "ipv4.ipv4_32": True,
            "ipv4.ipv6_32": False,
            "ipv4.ipv6_48": False,
            "ipv4.ipv6_64": False,
            "ipv6.ipv4_24": False,
            "ipv6.ipv4_32": False,
            "ipv6.ipv6_32": True,
            "ipv6.ipv6_48": True,
            "ipv6.ipv6_64": True,
        },
    ),
    Scenario(
        name="full-geolite-city-v4-en",
        editions=("GeoLite2-City-CSV",),
        profile="all_false",
        ip_versions="4",
        locales="en",
        geo4="000",
        geo6="000",
        full_archives=True,
        repeat_loader=False,
    ),
    Scenario(
        name="full-geolite-country-v6-ru",
        editions=("GeoLite2-Country-CSV",),
        profile="all_false",
        ip_versions="6",
        locales="ru",
        geo4="000",
        geo6="000",
        full_archives=True,
        repeat_loader=False,
    ),
]


SECTION_RE = re.compile(r"^\[([^]]+)]\s*$")
KEY_RE = re.compile(r"^(\s*)([^#;][^=]*?)\s*=\s*(.*?)\s*$")
GEO_BITS = {
    "geoname_id": 0,
    "registered_country_geoname_id": 1,
    "represented_country_geoname_id": 2,
}


def schema_name(scenario: Scenario) -> str:
    return "mm_" + scenario.name.replace("-", "_")


def mixed_value(section: str, key: str) -> str:
    checksum = sum(ord(character) for character in f"{section}.{key}")
    return "true" if checksum % 2 == 0 else "false"


def transformed_lines(template: str, scenario: Scenario, dbms: str) -> list[str]:
    lines = template.splitlines()
    output: list[str] = []
    section = ""
    skip_edition_values = False

    for line in lines:
        section_match = SECTION_RE.match(line)
        if section_match:
            section = section_match.group(1)
            skip_edition_values = False
            output.append(line)
            edition = section.rsplit(".location_filters", 1)[0]
            if section.endswith(".location_filters") and edition in scenario.editions and scenario.filters:
                output.append("# Active integration-test filters generated for this scenario.")
                for key, value in scenario.filters.items():
                    output.append(f"{key} = {value}")
            continue

        if skip_edition_values:
            if re.match(r"^\s+\S", line):
                continue
            skip_edition_values = False

        key_match = KEY_RE.match(line)
        if not key_match:
            output.append(line)
            continue

        indent, key, value = key_match.groups()
        key = key.strip()

        if section == "editions" and key == "edition_ids":
            output.append(f"{indent}edition_ids =")
            output.extend(f"  {edition}" for edition in scenario.editions)
            skip_edition_values = True
            continue

        if section == "settings":
            replacements = {
                "output_dir": "../../converted/matrix",
                "auto_execute_loader_sh": "false",
                "auto_delete_csvs": "false",
                "on_debug": "true",
            }
            if dbms == "mysql":
                replacements.update({
                    "mysql_command": "C:/Program Files/MySQL/MySQL Server 8.0/bin/mysql.exe",
                    "mysql_host": "127.0.0.1",
                    "mysql_port": "3308",
                })
            else:
                replacements.update({
                    "postgresql_command": "C:/PostgreSQL/16/bin/psql.exe",
                    "postgresql_host": "127.0.0.1",
                    "postgresql_port": "5435",
                    "postgresql_database": "maxmind",
                })
            if key in replacements:
                output.append(f"{indent}{key} = {replacements[key]}")
                continue

        edition = section.split(".", 1)[0]
        selected = edition in scenario.editions

        if section.endswith(".download"):
            if key == "license_key":
                output.append(f"{indent}license_key =")
                continue
            if key == "source_archive_uri":
                archive_map = FULL_ARCHIVES if scenario.full_archives else ARCHIVES
                archive_name = archive_map.get(edition, ARCHIVES[edition])
                output.append(f"{indent}source_archive_uri = ../data/{archive_name}")
                continue

        if selected and section.endswith(".database") and key == "schema_name":
            if scenario.keep_default_schemas:
                output.append(line)
            else:
                output.append(f"{indent}schema_name = {schema_name(scenario)}")
            continue

        if selected and section.endswith(".convert"):
            replacements = {
                "sql_bash_generator_file": "../../generators/default/functions.bash",
                "e_geoname_id_priority_columns": scenario.priority,
            }
            if scenario.ip_versions is not None:
                replacements["ip_versions"] = scenario.ip_versions
            if scenario.locales is not None:
                replacements["locales"] = scenario.locales
            if key in replacements:
                output.append(f"{indent}{key} = {replacements[key]}")
                continue

        columns_match = re.match(r"^(.+)\.columns\.(.+)$", section)
        if selected and columns_match and value.lower() in {"true", "false"}:
            table = columns_match.group(2)
            if scenario.profile == "all_true":
                new_value = "true"
            elif scenario.profile == "all_false":
                new_value = "false"
            else:
                new_value = mixed_value(section, key)

            override = scenario.column_overrides.get(f"{table}.{key}")
            if override is not None:
                new_value = "true" if override else "false"

            if key in GEO_BITS and table in {"ipv4", "ipv6"}:
                bits = scenario.geo4 if table == "ipv4" else scenario.geo6
                new_value = "true" if bits[GEO_BITS[key]] == "1" else "false"
            output.append(f"{indent}{key} = {new_value}")
            continue

        output.append(line)

    return output


def main() -> int:
    test_dir = Path(__file__).resolve().parent
    generated_dir = test_dir / "generated"
    generated_dir.mkdir(parents=True, exist_ok=True)
    (test_dir.parent / "converted" / "matrix").mkdir(parents=True, exist_ok=True)

    expected_files: set[Path] = set()
    manifest_rows = ["scenario\tdbms\tconfig\teditions\tschema\trepeat_loader\tfull_archives"]

    for dbms in ("mysql", "postgresql"):
        template = (test_dir / f"test.{dbms}.ini").read_text(encoding="utf-8-sig")
        for scenario in SCENARIOS:
            output_path = generated_dir / f"matrix-{scenario.name}.{dbms}.ini"
            output_path.write_text(
                "\n".join(transformed_lines(template, scenario, dbms)) + "\n",
                encoding="utf-8",
                newline="\n",
            )
            expected_files.add(output_path)
            schemas = "default" if scenario.keep_default_schemas else schema_name(scenario)
            manifest_rows.append(
                "\t".join((
                    scenario.name,
                    dbms,
                    output_path.name,
                    ",".join(scenario.editions),
                    schemas,
                    str(scenario.repeat_loader).lower(),
                    str(scenario.full_archives).lower(),
                ))
            )

    for stale_path in generated_dir.glob("matrix-*.ini"):
        if stale_path not in expected_files:
            stale_path.unlink()

    manifest_path = generated_dir / "manifest.tsv"
    manifest_path.write_text("\n".join(manifest_rows) + "\n", encoding="utf-8", newline="\n")
    print(f"generated {len(expected_files)} configs in {generated_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
