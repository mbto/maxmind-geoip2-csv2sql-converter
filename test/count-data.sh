#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)" || exit 1
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)" || exit 1
DATA_DIR="${PROJECT_DIR}/test/data"

PYTHON_CMD=()
for candidate in python3 python "py -3"; do
  read -r -a cmd <<< "$candidate"
  if command -v "${cmd[0]}" >/dev/null 2>&1 && "${cmd[@]}" -c 'import sys; raise SystemExit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1; then
    PYTHON_CMD=("${cmd[@]}")
    break
  fi
done

if [[ "${#PYTHON_CMD[@]}" -eq 0 ]]; then
  echo "Python 3 is required; install it or make python3/python/py available in PATH." >&2
  exit 1
fi

"${PYTHON_CMD[@]}" - "${DATA_DIR}" "$@" <<'PY'
import csv
import io
import re
import sys
import zipfile
from pathlib import Path

data_dir = Path(sys.argv[1])
archive_args = sys.argv[2:]
def resolve_archives():
    if archive_args:
        archives = []
        for arg in archive_args:
            path = Path(arg)
            if not path.is_absolute():
                path = data_dir / path
            archives.append(path)
        return archives
    return sorted(data_dir.glob("*.zip"))


def csv_reader(archive, member):
    handle = archive.open(member)
    text = io.TextIOWrapper(handle, encoding="utf-8-sig", newline="")
    return handle, csv.DictReader(text)


def find_member(names, suffix):
    matches = [name for name in names if name.endswith(suffix)]
    if not matches:
        raise RuntimeError(f"missing CSV in archive: {suffix}")
    return matches[0]


def detect_archive(names):
    for name in names:
        base = Path(name).name
        match = re.match(r"^((?:GeoLite2|GeoIP2|GeoIP)-(City|Country|Enterprise))-Locations-en\.csv$", base)
        if match:
            return match.group(1), match.group(2), name
    for name in names:
        base = Path(name).name
        match = re.match(r"^((?:GeoLite2|GeoIP2|GeoIP)-[A-Za-z0-9-]+)-Blocks-IPv4\.csv$", base)
        if match:
            return match.group(1), "Network", None
    raise RuntimeError("archive does not contain a supported CSV")


def schema_from_prefix(prefix):
    special = {
        "GeoIP2-City": "maxmind_geoip2_city",
        "GeoLite2-City": "maxmind_geolite2_city",
        "GeoIP2-Country": "maxmind_geoip2_country",
        "GeoLite2-Country": "maxmind_geolite2_country",
    }
    if prefix in special:
        return special[prefix]
    for vendor in ("GeoLite2-", "GeoIP2-", "GeoIP-"):
        if prefix.startswith(vendor):
            name = prefix[len(vendor):]
            break
    else:
        name = prefix
    return "maxmind_" + name.lower().replace("-", "_")


def count_blocks(archive, member):
    # Production network tables preserve source blocks even when every GeoName
    # source ID is NULL; lookup routines expose those rows as no_location.
    handle, reader = csv_reader(archive, member)
    with handle:
        return sum(1 for _ in reader)


def count_archive(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        prefix, kind, locations_member = detect_archive(names)
        schema = schema_from_prefix(prefix)
        if kind == "Network":
            rows = []
            for version in ("4", "6"):
                blocks_member = find_member(names, f"{prefix}-Blocks-IPv{version}.csv")
                handle, reader = csv_reader(archive, blocks_member)
                with handle:
                    rows.append((f"{schema}.ipv{version}", sum(1 for _ in reader)))
            return rows

        location_count = 0

        if kind in {"City", "Enterprise"}:
            country_keys = set()
            subdivision1 = set()
            subdivision2 = set()
            timezones = set()

        handle, reader = csv_reader(archive, locations_member)
        with handle:
            for row in reader:
                geoname_id = row.get("geoname_id", "")
                location_count += 1

                if kind in {"City", "Enterprise"}:
                    country_iso = row.get("country_iso_code", "")
                    country_key = country_iso if country_iso else f"#{geoname_id}"
                    country_keys.add(country_key)

                    subdivision_1_iso = row.get("subdivision_1_iso_code", "")
                    if subdivision_1_iso:
                        subdivision1.add((country_key, subdivision_1_iso))

                    subdivision_2_iso = row.get("subdivision_2_iso_code", "")
                    if subdivision_2_iso:
                        subdivision2.add((country_key, subdivision_2_iso))

                    time_zone = row.get("time_zone", "")
                    if time_zone:
                        timezones.add(time_zone)

        rows = []
        if kind in {"City", "Enterprise"}:
            rows.extend(
                [
                    (f"{schema}.timezone", len(timezones)),
                    (f"{schema}.country", len(country_keys)),
                    (f"{schema}.subdivision1", len(subdivision1)),
                    (f"{schema}.subdivision2", len(subdivision2)),
                    (f"{schema}.city", location_count),
                ]
            )
        else:
            rows.append((f"{schema}.country", location_count))

        for version in ("4", "6"):
            blocks_member = find_member(names, f"{prefix}-Blocks-IPv{version}.csv")
            rows.append(
                (
                    f"{schema}.ipv{version}",
                    count_blocks(archive, blocks_member),
                )
            )
        if kind == "Enterprise":
            isp_member = find_member(names, f"{prefix}-ISP.csv")
            handle, reader = csv_reader(archive, isp_member)
            with handle:
                rows.append((f"{schema}.isp", sum(1 for row in reader if row.get("isp_id", ""))))
        return rows


archives = resolve_archives()
if not archives:
    print(f"no zip archives found in {data_dir}", file=sys.stderr)
    sys.exit(1)

print("archive\ttable_name\trow_count")
for archive_path in archives:
    if not archive_path.is_file():
        print(f"missing archive: {archive_path}", file=sys.stderr)
        sys.exit(1)
    for table_name, row_count in count_archive(archive_path):
        print(f"{archive_path.name}\t{table_name}\t{row_count}")
PY
