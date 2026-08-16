-- Run after loading test/test.postgresql.ini. Result columns named
-- should_be_zero must contain 0. Synthetic network rows are rolled back.

SELECT * FROM maxmind_asn.get_dataset_metadata();
SELECT * FROM maxmind_asn.find_network_by_ip('1.0.0.1');
SELECT * FROM maxmind_asn.find_network_by_ip('203.0.113.1');
SELECT * FROM maxmind_asn.find_network_by_ip('999.1.1.1');
SELECT * FROM maxmind_asn.find_networks_by_json_ips(
    '["1.0.0.1", "bad", null, {"ip":"1.0.0.1"}, "1.0.0.1"]'::jsonb, 1, 40
);

SELECT * FROM maxmind_geoip2_city.get_dataset_metadata();
SELECT COUNT(*) AS should_be_zero
FROM maxmind_geoip2_city.dataset_metadata
WHERE schema_version <> 4;
SELECT * FROM maxmind_geoip2_city.find_geoname_ids_by_ip('81.2.69.142');
-- Source row 214.1.1.0/24 has no GeoName IDs but carries is_anycast=true.
SELECT * FROM maxmind_geoip2_city.find_geoname_ids_by_ip('214.1.1.1');
SELECT * FROM maxmind_geoip2_city.find_geoname_ids_by_ip('203.0.113.1');
SELECT * FROM maxmind_geoip2_city.find_geoname_ids_by_ip('2001:db8:::1');
SELECT * FROM maxmind_geoip2_city.find_geoname_ids_by_json_ips(
    '["81.2.69.142", "bad", null, {"ip":"1.1.1.1"}, "81.2.69.142"]'::jsonb, 1, 40
);

SELECT maxmind_geoip2_city.build_location_label_by_geoname_id(2643743, 'ru', 1, 1, 1) AS location_label;
SELECT (
    maxmind_geoip2_city.build_location_label_by_geoname_id(2643743, 'ru', 1, 1, 1)
    IS DISTINCT FROM
    maxmind_geoip2_city.build_location_label_by_geoname_id(2643743, '"ru"', 1, 1, 1)
)::integer AS should_be_zero;
SELECT * FROM maxmind_geoip2_city.build_location_labels_by_ip(
    '81.2.69.142', '["ru", "en", null]'::jsonb, 1, 1, 1
);
SELECT * FROM maxmind_geoip2_city.build_location_labels_by_json_geoname_ids(
    '[2643743, null, "bad", 2147483648]'::jsonb, 'ru', 1, 1, 1, 1, 40
);

WITH ip_payload AS (
    SELECT jsonb_agg('81.2.69.142'::text ORDER BY n) AS ips
    FROM generate_series(1, 85) n
), id_payload AS (
    SELECT jsonb_agg(2643743 ORDER BY n) AS geoname_ids
    FROM generate_series(1, 85) n
), checked AS (
    SELECT count(*) AS row_count, min(ord) AS first_ord, max(ord) AS last_ord,
           min(total_count) AS min_total_count, max(total_count) AS max_total_count
    FROM ip_payload p
    CROSS JOIN LATERAL maxmind_geoip2_city.find_networks_by_json_ips(p.ips, 2, 17)
    UNION ALL
    SELECT count(*), min(ord), max(ord), min(total_count), max(total_count)
    FROM ip_payload p
    CROSS JOIN LATERAL maxmind_geoip2_city.find_geoname_ids_by_json_ips(p.ips, 2, 17)
    UNION ALL
    SELECT count(*), min(ord), max(ord), min(total_count), max(total_count)
    FROM ip_payload p
    CROSS JOIN LATERAL maxmind_geoip2_city.find_e_geoname_ids_by_json_ips(p.ips, 2, 17)
    UNION ALL
    SELECT count(*), min(ord), max(ord), min(total_count), max(total_count)
    FROM ip_payload p
    CROSS JOIN LATERAL maxmind_geoip2_city.find_geoinfo_by_json_ips(
        p.ips, 1, 0, 0, 2, 17
    )
    UNION ALL
    SELECT count(*), min(ord), max(ord), min(total_count), max(total_count)
    FROM id_payload p
    CROSS JOIN LATERAL maxmind_geoip2_city.find_geoinfo_by_json_geoname_ids(
        p.geoname_ids, 1, 0, 0, 2, 17
    )
    UNION ALL
    SELECT count(*), min(ord), max(ord), min(total_count), max(total_count)
    FROM id_payload p
    CROSS JOIN LATERAL maxmind_geoip2_city.build_location_labels_by_json_geoname_ids(
        p.geoname_ids, 'ru', 1, 1, 1, 2, 17
    )
)
SELECT COUNT(*) AS should_be_zero
FROM checked
WHERE row_count <> 17 OR first_ord <> 18 OR last_ord <> 34
   OR min_total_count <> 85 OR max_total_count <> 85;

SELECT 2 - COUNT(*) AS should_be_zero
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'maxmind_geoip2_city'
  AND p.proname IN (
      'find_geoinfo_by_json_ips',
      'find_geoinfo_by_json_geoname_ids'
  )
  AND p.pronargs = 6
  AND pg_get_function_result(p.oid) NOT LIKE '%location_label%'
  AND pg_get_function_result(p.oid) LIKE '%geoname_id integer%'
  AND pg_get_function_result(p.oid) NOT LIKE '%e_geoname_id integer%';
SELECT 1 - COUNT(*) AS should_be_zero
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'maxmind_geoip2_city'
  AND p.proname = 'find_e_geoname_ids_by_json_ips'
  AND pg_get_function_result(p.oid) LIKE '%e_geoname_id integer%';
SELECT COUNT(*) AS should_be_zero
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'maxmind_geoip2_city'
  AND p.proname IN (
      'find_geoinfo_by_json_ips',
      'find_geoinfo_by_json_geoname_ids'
  )
  AND p.pronargs <> 6;

WITH base AS (
    SELECT location_en
    FROM maxmind_geoip2_city.find_geoinfo_by_json_geoname_ids(
        '[2643743]'::jsonb, 0, 0, 0, 1, 1
    )
), with_continent AS (
    SELECT location_en
    FROM maxmind_geoip2_city.find_geoinfo_by_json_geoname_ids(
        '[2643743]'::jsonb, 1, 0, 0, 1, 1
    )
), with_iso AS (
    SELECT location_en
    FROM maxmind_geoip2_city.find_geoinfo_by_json_geoname_ids(
        '[2643743]'::jsonb, 0, 1, 0, 1, 1
    )
), with_emoji AS (
    SELECT location_en
    FROM maxmind_geoip2_city.find_geoinfo_by_json_geoname_ids(
        '[2643743]'::jsonb, 0, 0, 1, 1, 1
    )
)
SELECT COUNT(*) AS should_be_zero
FROM base b
CROSS JOIN with_continent c
CROSS JOIN with_iso i
CROSS JOIN with_emoji e
WHERE b.location_en = c.location_en
   OR b.location_en = i.location_en
   OR b.location_en = e.location_en
   OR b.location_en LIKE 'Europe - %'
   OR b.location_en LIKE '%[GB]%'
   OR c.location_en NOT LIKE 'Europe - %'
   OR i.location_en NOT LIKE '%[GB]%';

SELECT COUNT(*) AS should_be_zero
FROM maxmind_geoip2_city.dataset_metadata
WHERE archive_root ~ '[/\\]'
   OR archive_root LIKE '%://%'
   OR archive_root LIKE '%license_key%';

SELECT COUNT(DISTINCT run_id) - 1 AS should_be_zero
FROM (
    SELECT run_id FROM maxmind_asn.dataset_metadata
    UNION ALL
    SELECT run_id FROM maxmind_geoip2_city.dataset_metadata
    UNION ALL
    SELECT run_id FROM maxmind_geoip2_country.dataset_metadata
) metadata;

SELECT COUNT(*) - COUNT(*) FILTER (WHERE
    (e_geoname_id IS NULL AND e_geoname_source_code IS NULL)
    OR (e_geoname_source_code = 1 AND geoname_id IS NOT NULL AND e_geoname_id = geoname_id)
    OR (e_geoname_source_code = 2 AND registered_country_geoname_id IS NOT NULL
        AND e_geoname_id = registered_country_geoname_id)
    OR (e_geoname_source_code = 3 AND represented_country_geoname_id IS NOT NULL
        AND e_geoname_id = represented_country_geoname_id)
) AS should_be_zero
FROM (
    SELECT e_geoname_id, e_geoname_source_code, geoname_id,
           registered_country_geoname_id, represented_country_geoname_id
    FROM maxmind_geoip2_city.ipv4
    UNION ALL
    SELECT e_geoname_id, e_geoname_source_code, geoname_id,
           registered_country_geoname_id, represented_country_geoname_id
    FROM maxmind_geoip2_city.ipv6
) checked_rows;

SELECT CASE
         WHEN count(*) = 1 AND bool_and(status = 'no_location' AND network IS NOT NULL)
         THEN 0 ELSE 1
       END AS should_be_zero
FROM maxmind_geoip2_city.find_geoname_ids_by_ip('214.1.1.1');

BEGIN;
INSERT INTO maxmind_geoip2_city.ipv4
    (network, start_ip, last_ip, e_geoname_id, e_geoname_source_code,
     geoname_id, registered_country_geoname_id, represented_country_geoname_id)
VALUES
    ('192.0.2.0/24'::cidr, '192.0.2.0'::inet, '192.0.2.255'::inet,
     6252001, 2, NULL, 6252001, NULL),
    ('198.51.100.0/24'::cidr, '198.51.100.0'::inet, '198.51.100.255'::inet,
     6252001, 3, NULL, NULL, 6252001),
    ('203.0.113.0/24'::cidr, '203.0.113.0'::inet, '203.0.113.255'::inet,
     6252001, 1, 6252001, 6252001, NULL);

SELECT * FROM maxmind_geoip2_city.find_geoname_ids_by_ip('192.0.2.1');
SELECT * FROM maxmind_geoip2_city.find_geoname_ids_by_ip('198.51.100.1');
SELECT * FROM maxmind_geoip2_city.find_geoname_ids_by_ip('203.0.113.1');
SELECT * FROM maxmind_geoip2_city.build_location_labels_by_ip('192.0.2.1', '["en"]'::jsonb, 1, 1, 1);
SELECT * FROM maxmind_geoip2_city.build_location_labels_by_ip('198.51.100.1', '["en"]'::jsonb, 1, 1, 1);
SELECT maxmind_geoip2_city.find_geoname_id_by_ip('192.0.2.1') AS geoname_id,
       maxmind_geoip2_city.find_e_geoname_id_by_ip('192.0.2.1') AS e_geoname_id;
ROLLBACK;
