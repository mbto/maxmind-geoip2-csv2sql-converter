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
                }, Map.ofEntries(
                        entry("country", 252),
                        entry("country includes which unknown", 2),
                        entry("ipv4", 417044),
                        entry("ipv4 ignored", 30)),
                        9818745},
                {new String[]{
                        "-i", "4",
                }, Map.ofEntries(
                        entry("country", 252),
                        entry("country includes which unknown", 2),
                        entry("ipv4", 417044),
                        entry("ipv4 ignored", 30)),
                        9818571},
                {new String[]{
                        "-i", "4",
                        "-l", "en,ru",
                }, Map.ofEntries(
                        entry("country", 252),
                        entry("country includes which unknown", 2),
                        entry("ipv4", 417044),
                        entry("ipv4 ignored", 30)),
                        9808716},
                {new String[]{
                        "-i", "4",
                        "-l", "en",
                }, Map.ofEntries(
                        entry("country", 252),
                        entry("country includes which unknown", 2),
                        entry("ipv4", 417044),
                        entry("ipv4 ignored", 30)),
                        9806066},
                {new String[]{
                        "-i", "6",
                        "-mm", "32",
                }, Map.ofEntries(
                        entry("country", 252),
                        entry("country includes which unknown", 2),
                        entry("ipv6", 270936),
                        entry("ipv6 ignored", 2)),
                        11650773},
                {new String[]{
                        "-i", "6",
                }, Map.ofEntries(
                        entry("country", 252),
                        entry("country includes which unknown", 2),
                        entry("ipv6", 270936),
                        entry("ipv6 ignored", 2)),
                        11649909},
                {new String[]{
                        "-i", "6",
                        "-l", "en,ru",
                }, Map.ofEntries(
                        entry("country", 252),
                        entry("country includes which unknown", 2),
                        entry("ipv6", 270936),
                        entry("ipv6 ignored", 2)),
                        11640054},
                {new String[]{
                        "-i", "6",
                        "-l", "en",
                }, Map.ofEntries(
                        entry("country", 252),
                        entry("country includes which unknown", 2),
                        entry("ipv6", 270936),
                        entry("ipv6 ignored", 2)),
                        11637404},
                {new String[]{
                        "-i", "4,6",
                        "-mm", "32",
                }, Map.ofEntries(
                        entry("country", 252),
                        entry("country includes which unknown", 2),
                        entry("ipv4", 417044),
                        entry("ipv4 ignored", 30),
                        entry("ipv6", 270936),
                        entry("ipv6 ignored", 2)),
                        21448126},
                {new String[]{
                        "-i", "4,6",
                }, Map.ofEntries(
                        entry("country", 252),
                        entry("country includes which unknown", 2),
                        entry("ipv4", 417044),
                        entry("ipv4 ignored", 30),
                        entry("ipv6", 270936),
                        entry("ipv6 ignored", 2)),
                        21447087},
                {new String[]{
                        "-i", "4,6",
                        "-l", "en,ru",
                }, Map.ofEntries(
                        entry("country", 252),
                        entry("country includes which unknown", 2),
                        entry("ipv4", 417044),
                        entry("ipv4 ignored", 30),
                        entry("ipv6", 270936),
                        entry("ipv6 ignored", 2)),
                        21437232},
                {new String[]{
                        "-i", "4,6",
                        "-l", "en",
                }, Map.ofEntries(
                        entry("country", 252),
                        entry("country includes which unknown", 2),
                        entry("ipv4", 417044),
                        entry("ipv4 ignored", 30),
                        entry("ipv6", 270936),
                        entry("ipv6 ignored", 2)),
                        21434582},
        });
    }

    @Test
    public void test() throws Throwable {
        assertStats(argsRaw, editionId, UUID.randomUUID().toString(), expectedStats, expectedArchiveFileSize);
    }
}