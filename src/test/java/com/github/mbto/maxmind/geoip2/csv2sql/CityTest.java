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
                }, Map.of(
                        "city", 121723,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 3566870,
                        "subdivision1", 3444,
                        "subdivision2", 1094,
                        "timezone", 408),
                        106689207},
                {new String[]{
                        "-i", "4",
                }, Map.of(
                        "city", 121723,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 3566870,
                        "subdivision1", 3444,
                        "subdivision2", 1094,
                        "timezone", 408),
                        106680973},
                {new String[]{
                        "-i", "4",
                        "-l", "en,ru",
                }, Map.of(
                        "city", 121723,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 3566870,
                        "subdivision1", 3444,
                        "subdivision2", 1094,
                        "timezone", 408),
                        106080700},
                {new String[]{
                        "-i", "4",
                        "-l", "en",
                }, Map.of(
                        "city", 121723,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 3566870,
                        "subdivision1", 3444,
                        "subdivision2", 1094,
                        "timezone", 408),
                        105805193},
                {new String[]{
                        "-i", "6",
                        "-mm", "32",
                }, Map.of(
                        "city", 121723,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv6", 355990,
                        "subdivision1", 3444,
                        "subdivision2", 1094,
                        "timezone", 408),
                        19317782},
                {new String[]{
                        "-i", "6",
                }, Map.of(
                        "city", 121723,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv6", 355990,
                        "subdivision1", 3444,
                        "subdivision2", 1094,
                        "timezone", 408),
                        19315938},

                {new String[]{
                        "-i", "6",
                        "-l", "en,ru",
                }, Map.of(
                        "city", 121723,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv6", 355990,
                        "subdivision1", 3444,
                        "subdivision2", 1094,
                        "timezone", 408),
                        18715665},
                {new String[]{
                        "-i", "6",
                        "-l", "en",
                }, Map.of(
                        "city", 121723,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv6", 355990,
                        "subdivision1", 3444,
                        "subdivision2", 1094,
                        "timezone", 408),
                        18440158},
                {new String[]{
                        "-i", "4,6",
                        "-mm", "32",
                }, Map.of(
                        "city", 121723,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 3566870,
                        "ipv6", 355990,
                        "subdivision1", 3444,
                        "subdivision2", 1094,
                        "timezone", 408),
                        123781884},
                {new String[]{
                        "-i", "4,6",
                }, Map.of(
                        "city", 121723,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 3566870,
                        "ipv6", 355990,
                        "subdivision1", 3444,
                        "subdivision2", 1094,
                        "timezone", 408),
                        123771806},
                {new String[]{
                        "-i", "4,6",
                        "-l", "en,ru",
                }, Map.of(
                        "city", 121723,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 3566870,
                        "ipv6", 355990,
                        "subdivision1", 3444,
                        "subdivision2", 1094,
                        "timezone", 408),
                        123171533},
                {new String[]{
                        "-i", "4,6",
                        "-l", "en",
                }, Map.of(
                        "city", 121723,
                        "city includes which unknown", 249,
                        "country", 252,
                        "country includes which unknown", 2,
                        "ipv4", 3566870,
                        "ipv6", 355990,
                        "subdivision1", 3444,
                        "subdivision2", 1094,
                        "timezone", 408),
                        122896026},
        });
    }

    @Test
    public void test() throws Throwable {
        assertStats(argsRaw, editionId, UUID.randomUUID().toString(), expectedStats, expectedArchiveFileSize);
    }
}