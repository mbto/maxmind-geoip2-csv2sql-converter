package com.github.mbto.maxmind.geoip2.csv2sql;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.runners.Parameterized;
import org.junit.runners.Parameterized.Parameter;

import java.util.Arrays;
import java.util.Collection;
import java.util.Map;
import java.util.UUID;

import static com.github.mbto.maxmind.geoip2.csv2sql.Constants.assertStats;
import static java.util.Map.entry;
import static org.junit.runners.Parameterized.Parameters;

/**
 * https://github.com/junit-team/junit4/wiki/Parameterized-tests
 */
@RunWith(Parameterized.class)
public class CityTest {
    private final String editionId = "GeoLite2-City-CSV";

    @Parameter
    public String[] argsRaw;
    @Parameter(1)
    public Map<String, Integer> expectedStats;
    @Parameter(2)
    public int expectedArchiveFileSize;

    @Parameters(name = "{index}: {2}")
    public static Collection<Object[]> data() {
        return Arrays.asList(new Object[][] {
                {new String[]{
                        "-i", "4",
                        "-mm", "32",
                }, Map.ofEntries(
                        entry("city", 114790),
                        entry("city includes which unknown", 249),
                        entry("country", 252),
                        entry("country includes which unknown", 2),
                        entry("ipv4", 3757625),
                        entry("ipv4 ignored", 30),
                        entry("subdivision1", 3379),
                        entry("subdivision2", 1082),
                        entry("timezone", 400)),
                        110337707},
                {new String[]{
                        "-i", "4",
                }, Map.of(
                        "city", 114790,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 3757625,
                        "ipv4 ignored", 30,
                        "subdivision1", 3379,
                        "subdivision2", 1082,
                        "timezone", 400),
                        110335462},
                {new String[]{
                        "-i", "4",
                        "-l", "en,ru",
                }, Map.of(
                        "city", 114790,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 3757625,
                        "ipv4 ignored", 30,
                        "subdivision1", 3379,
                        "subdivision2", 1082,
                        "timezone", 400),
                        109746077},
                {new String[]{
                        "-i", "4",
                        "-l", "en",
                }, Map.of(
                        "city", 114790,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 3757625,
                        "ipv4 ignored", 30,
                        "subdivision1", 3379,
                        "subdivision2", 1082,
                        "timezone", 400),
                        109481777},
                {new String[]{
                        "-i", "6",
                        "-mm", "32",
                }, Map.of(
                        "city", 114790,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv6", 1254770,
                        "ipv6 ignored", 2,
                        "subdivision1", 3379,
                        "subdivision2", 1082,
                        "timezone", 400),
                        58942598},
                {new String[]{
                        "-i", "6",
                }, Map.of(
                        "city", 114790,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv6", 1254770,
                        "ipv6 ignored", 2,
                        "subdivision1", 3379,
                        "subdivision2", 1082,
                        "timezone", 400),
                        58937011},

                {new String[]{
                        "-i", "6",
                        "-l", "en,ru",
                }, Map.of(
                        "city", 114790,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv6", 1254770,
                        "ipv6 ignored", 2,
                        "subdivision1", 3379,
                        "subdivision2", 1082,
                        "timezone", 400),
                        58347626},
                {new String[]{
                        "-i", "6",
                        "-l", "en",
                }, Map.of(
                        "city", 114790,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv6", 1254770,
                        "ipv6 ignored", 2,
                        "subdivision1", 3379,
                        "subdivision2", 1082,
                        "timezone", 400),
                        58083326},
                {new String[]{
                        "-i", "4,6",
                        "-mm", "32",
                }, Map.ofEntries(
                        entry("city", 114790),
                        entry("city includes which unknown", 249),
                        entry("country", 252),
                        entry("country includes which unknown", 2),
                        entry("ipv4", 3757625),
                        entry("ipv4 ignored", 30),
                        entry("ipv6", 1254770),
                        entry("ipv6 ignored", 2),
                        entry("subdivision1", 3379),
                        entry("subdivision2", 1082),
                        entry("timezone", 400)),
                        167150785},
                {new String[]{
                        "-i", "4,6",
                }, Map.ofEntries(
                        entry("city", 114790),
                        entry("city includes which unknown", 249),
                        entry("country", 252),
                        entry("country includes which unknown", 2),
                        entry("ipv4", 3757625),
                        entry("ipv4 ignored", 30),
                        entry("ipv6", 1254770),
                        entry("ipv6 ignored", 2),
                        entry("subdivision1", 3379),
                        entry("subdivision2", 1082),
                        entry("timezone", 400)),
                        167142948},
                {new String[]{
                        "-i", "4,6",
                        "-l", "en,ru",
                }, Map.ofEntries(
                        entry("city", 114790),
                        entry("city includes which unknown", 249),
                        entry("country", 252),
                        entry("country includes which unknown", 2),
                        entry("ipv4", 3757625),
                        entry("ipv4 ignored", 30),
                        entry("ipv6", 1254770),
                        entry("ipv6 ignored", 2),
                        entry("subdivision1", 3379),
                        entry("subdivision2", 1082),
                        entry("timezone", 400)),
                        166553563},
                {new String[]{
                        "-i", "4,6",
                        "-l", "en",
                }, Map.ofEntries(
                        entry("city", 114790),
                        entry("city includes which unknown", 249),
                        entry("country", 252),
                        entry("country includes which unknown", 2),
                        entry("ipv4", 3757625),
                        entry("ipv4 ignored", 30),
                        entry("ipv6", 1254770),
                        entry("ipv6 ignored", 2),
                        entry("subdivision1", 3379),
                        entry("subdivision2", 1082),
                        entry("timezone", 400)),
                        166289263},
        });
    }

    @Test
    public void test() throws Throwable {
        assertStats(argsRaw, editionId, UUID.randomUUID().toString(), expectedStats, expectedArchiveFileSize);
    }
}