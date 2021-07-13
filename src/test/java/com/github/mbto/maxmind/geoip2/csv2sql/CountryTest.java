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
import static org.junit.runners.Parameterized.Parameters;

/**
 * https://github.com/junit-team/junit4/wiki/Parameterized-tests
 */
@RunWith(Parameterized.class)
public class CountryTest {
    private final String editionId = "GeoLite2-Country-CSV";

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
                }, Map.of(
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 338608),
                        8043371},
                {new String[]{
                        "-i", "4",
                }, Map.of(
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 338608),
                        8042359},
                {new String[]{
                        "-i", "4",
                        "-l", "en,ru",
                }, Map.of(
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 338608),
                        8032271},
                {new String[]{
                        "-i", "4",
                        "-l", "en",
                }, Map.of(
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 338608),
                        8029644},
                {new String[]{
                        "-i", "6",
                        "-mm", "32",
                }, Map.of(
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv6", 110835),
                        5330598},
                {new String[]{
                        "-i", "6",
                }, Map.of(
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv6", 110835),
                        5330598},
                {new String[]{
                        "-i", "6",
                        "-l", "en,ru",
                }, Map.of(
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv6", 110835),
                        5320510},
                {new String[]{
                        "-i", "6",
                        "-l", "en",
                }, Map.of(
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv6", 110835),
                        5317883},
                {new String[]{
                        "-i", "4,6",
                        "-mm", "32",
                }, Map.of(
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 338608,
                        "ipv6", 110835),
                        13352349},
                {new String[]{
                        "-i", "4,6",
                }, Map.of(
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 338608,
                        "ipv6", 110835),
                        13351337},
                {new String[]{
                        "-i", "4,6",
                        "-l", "en,ru",
                }, Map.of(
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 338608,
                        "ipv6", 110835),
                        13341249},
                {new String[]{
                        "-i", "4,6",
                        "-l", "en",
                }, Map.of(
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 338608,
                        "ipv6", 110835),
                        13338622},
        });
    }

    @Test
    public void test() throws Throwable {
        assertStats(argsRaw, editionId, UUID.randomUUID().toString(), expectedStats, expectedArchiveFileSize);
    }
}