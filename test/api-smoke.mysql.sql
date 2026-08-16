-- Run after loading test/test.mysql.ini. Result columns named should_be_zero
-- must contain 0. Synthetic network rows are rolled back.

CALL maxmind_asn.get_dataset_metadata();
CALL maxmind_asn.find_network_by_ip('1.0.0.1');
CALL maxmind_asn.find_network_by_ip('203.0.113.1');
CALL maxmind_asn.find_network_by_ip('999.1.1.1');
CALL maxmind_asn.find_networks_by_json_ips(
    JSON_ARRAY('1.0.0.1', 'bad', NULL, JSON_OBJECT('ip', '1.0.0.1'), '1.0.0.1'), 1, 40
);

CALL maxmind_geoip2_city.get_dataset_metadata();
SELECT COUNT(*) AS should_be_zero
FROM maxmind_geoip2_city.dataset_metadata
WHERE schema_version <> 4;
CALL maxmind_geoip2_city.find_geoname_ids_by_ip('81.2.69.142');
-- Source row 214.1.1.0/24 has no GeoName IDs but carries is_anycast=1.
CALL maxmind_geoip2_city.find_geoname_ids_by_ip('214.1.1.1');
CALL maxmind_geoip2_city.find_geoname_ids_by_ip('203.0.113.1');
CALL maxmind_geoip2_city.find_geoname_ids_by_ip('2001:db8:::1');
CALL maxmind_geoip2_city.find_geoname_ids_by_json_ips(
    JSON_ARRAY('81.2.69.142', 'bad', NULL, JSON_OBJECT('ip', '1.1.1.1'), '81.2.69.142'), 1, 40
);

SELECT maxmind_geoip2_city.build_location_label_by_geoname_id(2643743, 'ru', 1, 1, 1) AS location_label;
SELECT NOT (
    maxmind_geoip2_city.build_location_label_by_geoname_id(2643743, 'ru', 1, 1, 1)
    <=> maxmind_geoip2_city.build_location_label_by_geoname_id(2643743, '"ru"', 1, 1, 1)
) AS should_be_zero;
CALL maxmind_geoip2_city.build_location_labels_by_ip(
    '81.2.69.142', JSON_ARRAY('ru', 'en', NULL), 1, 1, 1
);
CALL maxmind_geoip2_city.build_location_labels_by_json_geoname_ids(
    JSON_ARRAY(2643743, NULL, 'bad', 2147483648), 'ru', 1, 1, 1, 1, 40
);

-- With per_page=17, page 2 must contain ord 18..34 and total_count=45.
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 45)
SELECT JSON_ARRAYAGG('81.2.69.142') INTO @paged_ips FROM seq;
CALL maxmind_geoip2_city.find_networks_by_json_ips(@paged_ips, 2, 17);
CALL maxmind_geoip2_city.find_geoname_ids_by_json_ips(@paged_ips, 2, 17);
CALL maxmind_geoip2_city.find_e_geoname_ids_by_json_ips(@paged_ips, 2, 17);
CALL maxmind_geoip2_city.find_geoinfo_by_json_ips(@paged_ips, 1, 0, 0, 2, 17);
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 45)
SELECT JSON_ARRAYAGG(2643743) INTO @paged_geoname_ids FROM seq;
CALL maxmind_geoip2_city.find_geoinfo_by_json_geoname_ids(
    @paged_geoname_ids, 1, 0, 0, 2, 17
);
CALL maxmind_geoip2_city.find_geoinfo_by_json_geoname_ids(
    JSON_ARRAY(2643743), 0, 0, 0, 1, 1
);
CALL maxmind_geoip2_city.find_geoinfo_by_json_geoname_ids(
    JSON_ARRAY(2643743), 1, 1, 1, 1, 1
);
SELECT COUNT(*) AS should_be_zero
FROM (
    SELECT p.SPECIFIC_NAME
    FROM information_schema.PARAMETERS p
    WHERE p.SPECIFIC_SCHEMA = 'maxmind_geoip2_city'
      AND p.SPECIFIC_NAME IN (
          'find_geoinfo_by_json_ips',
          'find_geoinfo_by_json_geoname_ids'
      )
      AND p.PARAMETER_MODE = 'IN'
    GROUP BY p.SPECIFIC_NAME
    HAVING COUNT(*) <> 6
) invalid_geoinfo_signature;
SELECT 2 - COUNT(*) AS should_be_zero
FROM information_schema.ROUTINES r
WHERE r.ROUTINE_SCHEMA = 'maxmind_geoip2_city'
  AND r.ROUTINE_NAME IN (
      'find_geoinfo_by_json_ips',
      'find_geoinfo_by_json_geoname_ids'
  )
  AND r.ROUTINE_DEFINITION NOT LIKE '%location_label%'
  AND r.ROUTINE_DEFINITION LIKE '%AS `geoname_id`%'
  AND r.ROUTINE_DEFINITION NOT LIKE '%AS `e_geoname_id`%';
SELECT COUNT(*) AS should_be_zero
FROM information_schema.ROUTINES r
WHERE r.ROUTINE_SCHEMA = 'maxmind_geoip2_city'
  AND r.ROUTINE_NAME = 'find_e_geoname_ids_by_json_ips'
  AND r.ROUTINE_DEFINITION LIKE '%i.`geoname_id` AS `e_geoname_id`%';
CALL maxmind_geoip2_city.build_location_labels_by_json_geoname_ids(
    @paged_geoname_ids, 'ru', 1, 1, 1, 2, 17
);

SELECT COUNT(*) AS should_be_zero
FROM maxmind_geoip2_city.dataset_metadata
WHERE archive_root REGEXP '[/\\\\]'
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

SELECT SUM(invalid_row) AS should_be_zero
FROM (
    SELECT CASE WHEN
        (e_geoname_id IS NULL AND e_geoname_source_code IS NULL)
        OR (e_geoname_source_code = 1 AND geoname_id IS NOT NULL AND e_geoname_id = geoname_id)
        OR (e_geoname_source_code = 2 AND registered_country_geoname_id IS NOT NULL
            AND e_geoname_id = registered_country_geoname_id)
        OR (e_geoname_source_code = 3 AND represented_country_geoname_id IS NOT NULL
            AND e_geoname_id = represented_country_geoname_id)
        THEN 0 ELSE 1 END AS invalid_row
    FROM maxmind_geoip2_city.ipv4
    UNION ALL
    SELECT CASE WHEN
        (e_geoname_id IS NULL AND e_geoname_source_code IS NULL)
        OR (e_geoname_source_code = 1 AND geoname_id IS NOT NULL AND e_geoname_id = geoname_id)
        OR (e_geoname_source_code = 2 AND registered_country_geoname_id IS NOT NULL
            AND e_geoname_id = registered_country_geoname_id)
        OR (e_geoname_source_code = 3 AND represented_country_geoname_id IS NOT NULL
            AND e_geoname_id = represented_country_geoname_id)
        THEN 0 ELSE 1 END
    FROM maxmind_geoip2_city.ipv6
) checked_rows;

SELECT CASE
         WHEN COUNT(*) = 1
          AND SUM(e_geoname_id IS NULL AND e_geoname_source_code IS NULL AND is_anycast = 1) = 1
         THEN 0 ELSE 1
       END AS should_be_zero
FROM maxmind_geoip2_city.ipv4
WHERE network = '214.1.1.0/24';

START TRANSACTION;
INSERT INTO maxmind_geoip2_city.ipv4
    (network, start_ip, last_ip, e_geoname_id, e_geoname_source_code,
     geoname_id, registered_country_geoname_id, represented_country_geoname_id)
VALUES
    ('192.0.2.0/24', INET_ATON('192.0.2.0'), INET_ATON('192.0.2.255'),
     6252001, 2, NULL, 6252001, NULL),
    ('198.51.100.0/24', INET_ATON('198.51.100.0'), INET_ATON('198.51.100.255'),
     6252001, 3, NULL, NULL, 6252001),
    ('203.0.113.0/24', INET_ATON('203.0.113.0'), INET_ATON('203.0.113.255'),
     6252001, 1, 6252001, 6252001, NULL);

CALL maxmind_geoip2_city.find_geoname_ids_by_ip('192.0.2.1');
CALL maxmind_geoip2_city.find_geoname_ids_by_ip('198.51.100.1');
CALL maxmind_geoip2_city.find_geoname_ids_by_ip('203.0.113.1');
CALL maxmind_geoip2_city.build_location_labels_by_ip('192.0.2.1', JSON_ARRAY('en'), 1, 1, 1);
CALL maxmind_geoip2_city.build_location_labels_by_ip('198.51.100.1', JSON_ARRAY('en'), 1, 1, 1);
SELECT maxmind_geoip2_city.find_geoname_id_by_ip('192.0.2.1') AS geoname_id,
       maxmind_geoip2_city.find_e_geoname_id_by_ip('192.0.2.1') AS e_geoname_id;
ROLLBACK;
