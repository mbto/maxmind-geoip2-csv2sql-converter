package com.github.mbto.maxmind.geoip2.csv2sql.utils;

import java.util.LinkedHashSet;
import java.util.Set;

import static java.util.Arrays.asList;

public interface Constants {
    String SOFTWARE_NAME = "maxmind-geoip2-csv2sql-converter";

    String SOFTWARE_INFO = "MaxMind GeoIP2 csv2sql Converter v1.1\nhttps://github.com/mbto/" + SOFTWARE_NAME;

    Set<String> supportedLocales = new LinkedHashSet<>(
            asList("en", "ru", "de", "es", "fr", "ja", "pt-BR", "zh-CN"));

    Set<Integer> supportedIpVersions = new LinkedHashSet<>(asList(4, 6));

    String DEFAULT_ARCHIVE_NAME = "maxmind-geoip2-csv2sql.zip";

    String CONFIG_NAME_FORMAT = "[Edition ID].[DBMS name].[Profile name].ini";

    String IP_VERSION_PREFIX = "ipv";
}