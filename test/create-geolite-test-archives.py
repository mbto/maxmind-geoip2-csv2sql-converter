#!/usr/bin/env python3
"""Create small, referentially consistent GeoLite2 City/Country test ZIPs."""

from __future__ import annotations

import csv
import io
import sys
import zipfile
from pathlib import Path


LOCALES = ("en", "ru", "de", "es", "fr", "ja", "pt-BR", "zh-CN")
GEO_FIELDS = (
    "geoname_id",
    "registered_country_geoname_id",
    "represented_country_geoname_id",
)
BLOCK_LIMIT = 300
EXTRA_LOCATION_LIMIT = 200
ZIP_TIMESTAMP = (2020, 1, 1, 0, 0, 0)


def read_csv(archive: zipfile.ZipFile, member: str) -> tuple[list[str], list[dict[str, str]]]:
    with archive.open(member) as source:
        text = io.TextIOWrapper(source, encoding="utf-8-sig", newline="")
        reader = csv.DictReader(text)
        if reader.fieldnames is None:
            raise RuntimeError(f"CSV has no header: {member}")
        return list(reader.fieldnames), list(reader)


def find_member(archive: zipfile.ZipFile, filename: str) -> str:
    matches = [name for name in archive.namelist() if name.endswith(f"/{filename}")]
    if len(matches) != 1:
        raise RuntimeError(f"expected one {filename}, found {len(matches)}")
    return matches[0]


def encode_csv(fieldnames: list[str], rows: list[dict[str, str]]) -> bytes:
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=fieldnames, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue().encode("utf-8")


def write_member(archive: zipfile.ZipFile, member: str, data: bytes) -> None:
    info = zipfile.ZipInfo(member, ZIP_TIMESTAMP)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o100644 << 16
    archive.writestr(info, data)


def create_sample(data_dir: Path, kind: str) -> Path:
    source_path = data_dir / f"GeoLite2-{kind}-CSV_20260605.zip"
    output_path = data_dir / f"GeoLite2-{kind}-CSV_Example.zip"
    prefix = f"GeoLite2-{kind}"
    output_root = f"GeoLite2-{kind}-CSV_Example"

    if not source_path.is_file():
        raise RuntimeError(f"source archive is missing: {source_path}")

    with zipfile.ZipFile(source_path) as source:
        selected_blocks: dict[str, tuple[list[str], list[dict[str, str]]]] = {}
        selected_geoname_ids: set[str] = set()

        for version in ("4", "6"):
            filename = f"{prefix}-Blocks-IPv{version}.csv"
            fieldnames, all_rows = read_csv(source, find_member(source, filename))
            rows = all_rows[:BLOCK_LIMIT]
            selected_blocks[filename] = (fieldnames, rows)
            for row in rows:
                for field in GEO_FIELDS:
                    value = row.get(field, "").strip()
                    if value:
                        selected_geoname_ids.add(value)

        en_filename = f"{prefix}-Locations-en.csv"
        en_fields, en_rows = read_csv(source, find_member(source, en_filename))
        for row in en_rows[:EXTRA_LOCATION_LIMIT]:
            value = row.get("geoname_id", "").strip()
            if value:
                selected_geoname_ids.add(value)

        selected_locations: dict[str, tuple[list[str], list[dict[str, str]]]] = {}
        for locale in LOCALES:
            filename = f"{prefix}-Locations-{locale}.csv"
            fieldnames, rows = read_csv(source, find_member(source, filename))
            selected = [row for row in rows if row.get("geoname_id", "") in selected_geoname_ids]
            selected_locations[filename] = (fieldnames, selected)

    temporary_path = output_path.with_suffix(".zip.tmp")
    with zipfile.ZipFile(temporary_path, "w") as output:
        for filename, (fieldnames, rows) in selected_locations.items():
            write_member(output, f"{output_root}/{filename}", encode_csv(fieldnames, rows))
        for filename, (fieldnames, rows) in selected_blocks.items():
            write_member(output, f"{output_root}/{filename}", encode_csv(fieldnames, rows))

    temporary_path.replace(output_path)
    print(
        f"created {output_path.name}: "
        f"{len(selected_geoname_ids)} location IDs, "
        f"{sum(len(rows) for _, rows in selected_blocks.values())} block rows"
    )
    return output_path


def main() -> int:
    data_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent / "data"
    data_dir = data_dir.resolve()
    create_sample(data_dir, "City")
    create_sample(data_dir, "Country")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
