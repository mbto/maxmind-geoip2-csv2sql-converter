package com.github.mbto.maxmind.geoip2.csv2sql.streaming;

import com.github.jgonian.ipmath.*;
import com.github.mbto.maxmind.geoip2.csv2sql.utils.CsvHolder;
import com.github.mbto.maxmind.geoip2.csv2sql.utils.EmojiHolder;
import com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder.ParseUtils;
import lombok.Getter;
import lombok.Setter;
import lombok.ToString;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.function.Function;

/**
 * country_iso_code[v]: country_name[v] subdivision_1_iso_code[vx] subdivision_1_iso_code[vx] city_name[vx]
 * country_iso_code[x]: country_name[x] subdivision_1_iso_code[x] subdivision_2_iso_code[x] city_name[x]
 * subdivision_1_iso_code[v]: subdivision_1_name[vx] subdivision_2_iso_code[vx] city_name[vx]
 * subdivision_1_iso_code[x]: subdivision_1_name[x] subdivision_2_iso_code[x] city_name[vx]
 * subdivision_1_name[x]: subdivision_1_iso_code[vx]
 *
 * subdivision_2_iso_code[v]: subdivision_1_iso_code[v] subdivision_2_name[vx] city_name[vx]
 * subdivision_2_iso_code[x]: subdivision_1_iso_code[vx] subdivision_2_name[x] city_name[vx]
 * subdivision_2_name[x]: subdivision_2_iso_code[vx]
 *
 * city_name[v]: country_iso_code[v] subdivision_1_iso_code[vx] subdivision_2_iso_code[vx]
 * city_name[x]: country_iso_code[v] subdivision_1_iso_code[vx] subdivision_2_iso_code[vx]
 */
@Getter
public class Location {
    /**
     * independent value by group name
     * "geoname_id" -> "5819"
     * "locale_code" -> "en"
     * "continent_code" -> "EU"
     * "country_iso_code" -> "CY"
     * "subdivision_1_iso_code" -> "02"
     * "subdivision_2_iso_code" -> null
     * "metro_code" -> null
     * "time_zone" -> "Asia/Nicosia"
     * "is_in_european_union" -> "1"
     */
    private final Map<String, String> values;
    /**
     * aggregated values by locale_code key = "en"
     * "geoname_id" -> "5819"
     * "locale_code" -> "en"
     * "continent_code" -> "EU"
     * "continent_name" -> "Europe"
     * "country_iso_code" -> "CY"
     * "country_name" -> "Cyprus"
     * "subdivision_1_iso_code" -> "02"
     * "subdivision_1_name" -> "Limassol District"
     * "subdivision_2_iso_code" -> null
     * "subdivision_2_name" -> null
     * "city_name" -> "Souni"
     * "metro_code" -> null
     * "time_zone" -> "Asia/Nicosia"
     * "is_in_european_union" -> "1"
     */
    private final Map<String, LocationData> localeValues = new LinkedHashMap<>();
    /**
     * counter by synthetic key
     * timezone.id -> N, country.id -> N, subdivision1.id -> N, subdivision2.id -> N, city.id -> N
     */
    private final Map<String, Integer> keys = new LinkedHashMap<>(5, 1f);
    private final String emoji;

    public Location(CsvHolder csvHolder) {
        values = csvHolder.copyValueByGroupNameMap(entry -> {
            String groupName = entry.getKey();
            return !groupName.endsWith("_name");
        });
        emoji = EmojiHolder.get(values.get("country_iso_code"));
    }

    public void aggregateValues(CsvHolder csvHolder) {
        String localeCode = csvHolder.group("locale_code");
        localeValues.put(localeCode, new LocationData(csvHolder));
    }

    public void setId(String key, int value) {
        keys.put(key + ".id", value);
    }

    @Override
    public String toString() {
        return "Location{" +
                "values.size=" + values.size() +
                ", localeValues.size=" + localeValues.size() +
                ", keys.size=" + keys.size() +
                ", emoji='" + emoji + "'}";
    }

    @Getter
    public static class LocationData {
        private final Map<String, String> values;

        public LocationData(CsvHolder csvHolder) {
            values = csvHolder.copyValueByGroupNameMap(entry -> true);
        }

        public void put(String key, String value) {
            values.put(key, value);
        }

        public String get(String key) {
            return values.get(key);
        }
    }

    /**
     * From https://github.com/maxmind/geoip2-csv-converter geoip2-csv-converter.exe
     * CIDR (-include-cidr)
     * <p>
     * This will include the network in CIDR notation in the network column as it is in the original CSV.
     * Range (-include-range)
     * <p>
     * This adds network_start_ip and network_last_ip columns. These are string representations of the first and last IP address in the network.
     * Integer Range (-include-integer-range)
     * <p>
     * This adds network_start_integer and network_last_integer columns. These are integer representations of the first and last IP address in the network.
     * Hex Range (-include-hex-range)
     * <p>
     * This adds network_start_hex and network_last_hex columns. These are hexadecimal representations of the first and last IP address in the network.
     * <p>
     * network:                                    1.0.0.0/24
     * network_start_ip,network_last_ip:           1.0.0.0                              1.0.0.255
     * network_start_integer,network_last_integer: 16777216                             16777471
     * network_start_hex,network_last_hex:         1000000                              10000ff
     * <p>
     * network:                                    2a7:1c44:39f3:1b::/64
     * network_start_ip,network_last_ip:           2a7:1c44:39f3:1b::                    2a7:1c44:39f3:1b:ffff:ffff:ffff:ffff
     * network_start_integer,network_last_integer: 3526142879863516208564147688489091072 3526142879863516227010891762198642687
     * network_start_hex,network_last_hex:         2a71c4439f3001b0000000000000000       2a71c4439f3001bffffffffffffffff
     */
    @Getter
    @ToString
    public static class IPBlock {
        private final Map<String, String> values;
        private final AbstractIpRange<?, ?> range;
        @Setter
        private Integer priorityGeonameId;

        public IPBlock(CsvHolder csvHolder, Function<String, AbstractIpRange<?, ?>> parseCidrFunc) {
            values = csvHolder.copyValueByGroupNameMap(entry -> true);
            String network = values.get("network");
            range = parseCidrFunc.apply(network);
        }
        /**
         * Invokes from template
         */
        public String startToHex() {
            return zeroLeftPad(range.start().asBigInteger().toString(16));
        }
        /**
         * Invokes from template
         */
        public String endToHex() {
            return zeroLeftPad(range.end().asBigInteger().toString(16));
        }

        private String zeroLeftPad(String hex) {
            return hex.length() % 2 != 0 ? "0" + hex : hex;
        }
    }
}