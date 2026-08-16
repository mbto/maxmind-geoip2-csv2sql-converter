SELECT 'maxmind_anonymous_ip.ipv4' AS table_name, COUNT(*) AS row_count FROM maxmind_anonymous_ip.ipv4
UNION ALL
SELECT 'maxmind_anonymous_ip.ipv6' AS table_name, COUNT(*) AS row_count FROM maxmind_anonymous_ip.ipv6
UNION ALL
SELECT 'maxmind_anonymous_plus.ipv4' AS table_name, COUNT(*) AS row_count FROM maxmind_anonymous_plus.ipv4
UNION ALL
SELECT 'maxmind_anonymous_plus.ipv6' AS table_name, COUNT(*) AS row_count FROM maxmind_anonymous_plus.ipv6
UNION ALL
SELECT 'maxmind_asn.ipv4' AS table_name, COUNT(*) AS row_count FROM maxmind_asn.ipv4
UNION ALL
SELECT 'maxmind_asn.ipv6' AS table_name, COUNT(*) AS row_count FROM maxmind_asn.ipv6
UNION ALL
SELECT 'maxmind_geoip2_city.timezone' AS table_name, COUNT(*) AS row_count FROM maxmind_geoip2_city.timezone
UNION ALL
SELECT 'maxmind_geoip2_city.country' AS table_name, COUNT(*) AS row_count FROM maxmind_geoip2_city.country
UNION ALL
SELECT 'maxmind_geoip2_city.subdivision1' AS table_name, COUNT(*) AS row_count FROM maxmind_geoip2_city.subdivision1
UNION ALL
SELECT 'maxmind_geoip2_city.subdivision2' AS table_name, COUNT(*) AS row_count FROM maxmind_geoip2_city.subdivision2
UNION ALL
SELECT 'maxmind_geoip2_city.city' AS table_name, COUNT(*) AS row_count FROM maxmind_geoip2_city.city
UNION ALL
SELECT 'maxmind_geoip2_city.ipv4' AS table_name, COUNT(*) AS row_count FROM maxmind_geoip2_city.ipv4
UNION ALL
SELECT 'maxmind_geoip2_city.ipv6' AS table_name, COUNT(*) AS row_count FROM maxmind_geoip2_city.ipv6
UNION ALL
SELECT 'maxmind_geolite2_city.timezone' AS table_name, COUNT(*) AS row_count FROM maxmind_geolite2_city.timezone
UNION ALL
SELECT 'maxmind_geolite2_city.country' AS table_name, COUNT(*) AS row_count FROM maxmind_geolite2_city.country
UNION ALL
SELECT 'maxmind_geolite2_city.subdivision1' AS table_name, COUNT(*) AS row_count FROM maxmind_geolite2_city.subdivision1
UNION ALL
SELECT 'maxmind_geolite2_city.subdivision2' AS table_name, COUNT(*) AS row_count FROM maxmind_geolite2_city.subdivision2
UNION ALL
SELECT 'maxmind_geolite2_city.city' AS table_name, COUNT(*) AS row_count FROM maxmind_geolite2_city.city
UNION ALL
SELECT 'maxmind_geolite2_city.ipv4' AS table_name, COUNT(*) AS row_count FROM maxmind_geolite2_city.ipv4
UNION ALL
SELECT 'maxmind_geolite2_city.ipv6' AS table_name, COUNT(*) AS row_count FROM maxmind_geolite2_city.ipv6
UNION ALL
SELECT 'maxmind_connection_type.ipv4' AS table_name, COUNT(*) AS row_count FROM maxmind_connection_type.ipv4
UNION ALL
SELECT 'maxmind_connection_type.ipv6' AS table_name, COUNT(*) AS row_count FROM maxmind_connection_type.ipv6
UNION ALL
SELECT 'maxmind_geoip2_country.country' AS table_name, COUNT(*) AS row_count FROM maxmind_geoip2_country.country
UNION ALL
SELECT 'maxmind_geoip2_country.ipv4' AS table_name, COUNT(*) AS row_count FROM maxmind_geoip2_country.ipv4
UNION ALL
SELECT 'maxmind_geoip2_country.ipv6' AS table_name, COUNT(*) AS row_count FROM maxmind_geoip2_country.ipv6
UNION ALL
SELECT 'maxmind_geolite2_country.country' AS table_name, COUNT(*) AS row_count FROM maxmind_geolite2_country.country
UNION ALL
SELECT 'maxmind_geolite2_country.ipv4' AS table_name, COUNT(*) AS row_count FROM maxmind_geolite2_country.ipv4
UNION ALL
SELECT 'maxmind_geolite2_country.ipv6' AS table_name, COUNT(*) AS row_count FROM maxmind_geolite2_country.ipv6
UNION ALL
SELECT 'maxmind_domain.ipv4' AS table_name, COUNT(*) AS row_count FROM maxmind_domain.ipv4
UNION ALL
SELECT 'maxmind_domain.ipv6' AS table_name, COUNT(*) AS row_count FROM maxmind_domain.ipv6
UNION ALL
SELECT 'maxmind_enterprise.timezone' AS table_name, COUNT(*) AS row_count FROM maxmind_enterprise.timezone
UNION ALL
SELECT 'maxmind_enterprise.country' AS table_name, COUNT(*) AS row_count FROM maxmind_enterprise.country
UNION ALL
SELECT 'maxmind_enterprise.subdivision1' AS table_name, COUNT(*) AS row_count FROM maxmind_enterprise.subdivision1
UNION ALL
SELECT 'maxmind_enterprise.subdivision2' AS table_name, COUNT(*) AS row_count FROM maxmind_enterprise.subdivision2
UNION ALL
SELECT 'maxmind_enterprise.city' AS table_name, COUNT(*) AS row_count FROM maxmind_enterprise.city
UNION ALL
SELECT 'maxmind_enterprise.ipv4' AS table_name, COUNT(*) AS row_count FROM maxmind_enterprise.ipv4
UNION ALL
SELECT 'maxmind_enterprise.ipv6' AS table_name, COUNT(*) AS row_count FROM maxmind_enterprise.ipv6
UNION ALL
SELECT 'maxmind_enterprise.isp' AS table_name, COUNT(*) AS row_count FROM maxmind_enterprise.isp
UNION ALL
SELECT 'maxmind_ip_risk.ipv4' AS table_name, COUNT(*) AS row_count FROM maxmind_ip_risk.ipv4
UNION ALL
SELECT 'maxmind_ip_risk.ipv6' AS table_name, COUNT(*) AS row_count FROM maxmind_ip_risk.ipv6
UNION ALL
SELECT 'maxmind_isp.ipv4' AS table_name, COUNT(*) AS row_count FROM maxmind_isp.ipv4
UNION ALL
SELECT 'maxmind_isp.ipv6' AS table_name, COUNT(*) AS row_count FROM maxmind_isp.ipv6
UNION ALL
SELECT 'maxmind_residential_proxy.ipv4' AS table_name, COUNT(*) AS row_count FROM maxmind_residential_proxy.ipv4
UNION ALL
SELECT 'maxmind_residential_proxy.ipv6' AS table_name, COUNT(*) AS row_count FROM maxmind_residential_proxy.ipv6
UNION ALL
SELECT 'maxmind_static_ip_score.ipv4' AS table_name, COUNT(*) AS row_count FROM maxmind_static_ip_score.ipv4
UNION ALL
SELECT 'maxmind_static_ip_score.ipv6' AS table_name, COUNT(*) AS row_count FROM maxmind_static_ip_score.ipv6
UNION ALL
SELECT 'maxmind_user_count.ipv4' AS table_name, COUNT(*) AS row_count FROM maxmind_user_count.ipv4
UNION ALL
SELECT 'maxmind_user_count.ipv6' AS table_name, COUNT(*) AS row_count FROM maxmind_user_count.ipv6;

SELECT 'maxmind_anonymous_ip.dataset_metadata' AS table_name, COUNT(*) AS row_count FROM maxmind_anonymous_ip.dataset_metadata
UNION ALL
SELECT 'maxmind_anonymous_plus.dataset_metadata', COUNT(*) FROM maxmind_anonymous_plus.dataset_metadata
UNION ALL
SELECT 'maxmind_asn.dataset_metadata', COUNT(*) FROM maxmind_asn.dataset_metadata
UNION ALL
SELECT 'maxmind_geoip2_city.dataset_metadata', COUNT(*) FROM maxmind_geoip2_city.dataset_metadata
UNION ALL
SELECT 'maxmind_geolite2_city.dataset_metadata', COUNT(*) FROM maxmind_geolite2_city.dataset_metadata
UNION ALL
SELECT 'maxmind_connection_type.dataset_metadata', COUNT(*) FROM maxmind_connection_type.dataset_metadata
UNION ALL
SELECT 'maxmind_geoip2_country.dataset_metadata', COUNT(*) FROM maxmind_geoip2_country.dataset_metadata
UNION ALL
SELECT 'maxmind_geolite2_country.dataset_metadata', COUNT(*) FROM maxmind_geolite2_country.dataset_metadata
UNION ALL
SELECT 'maxmind_domain.dataset_metadata', COUNT(*) FROM maxmind_domain.dataset_metadata
UNION ALL
SELECT 'maxmind_enterprise.dataset_metadata', COUNT(*) FROM maxmind_enterprise.dataset_metadata
UNION ALL
SELECT 'maxmind_ip_risk.dataset_metadata', COUNT(*) FROM maxmind_ip_risk.dataset_metadata
UNION ALL
SELECT 'maxmind_isp.dataset_metadata', COUNT(*) FROM maxmind_isp.dataset_metadata
UNION ALL
SELECT 'maxmind_residential_proxy.dataset_metadata', COUNT(*) FROM maxmind_residential_proxy.dataset_metadata
UNION ALL
SELECT 'maxmind_static_ip_score.dataset_metadata', COUNT(*) FROM maxmind_static_ip_score.dataset_metadata
UNION ALL
SELECT 'maxmind_user_count.dataset_metadata', COUNT(*) FROM maxmind_user_count.dataset_metadata;
