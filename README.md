#### Features:
* Downloads latest archive `GeoLite2-(Country|City)-CSV_%Date%.zip` using MaxMind API https://www.maxmind.com/ by [free license key](https://support.maxmind.com/hc/en-us/articles/4407111582235-Generate-a-License-Key)
* Converts files `GeoLite2-(Country|City)-Locations-%LocaleCode%.csv, GeoLite2-(Country|City)-Blocks-(IPv4|IPv6).csv` to SQL DDL/DML
* Builds archive `maxmind-geoip2-csv2sql.zip` with scripts splitted per N megabytes, using template engine
  (Example: If MySQL server `max_allowed_packet` parameter is too small - [64 MB by default](https://dev.mysql.com/doc/refman/8.0/en/server-system-variables.html#sysvar_max_allowed_packet))
* Appends emoji country flags 🇦🇩 🇦🇪 🇦🇫 🇦🇬 🇦🇮 🇦🇱 🇦🇲 🇦🇴 🇦🇶 🇦🇷 🇦🇸 🇦🇹 🇦🇺 🇦🇼 🇦🇽 🇦🇿 🇧🇦 🇧🇧 🇧🇩 🇧🇪 🇧🇫 🇧🇬 🇧🇭 🇧🇮 🇧🇯 🇧🇱 🇧🇲 🇧🇳 🇧🇴 🇧🇶 🇧🇷 🇧🇸 🇧🇹 🇧🇻 🇧🇼 🇧🇾...
* Supports MaxMind edition IDs: `GeoLite2-Country-CSV, GeoLite2-City-CSV`; `IPv4, IPv6`; Locations locale codes: `en, ru, de, es, fr, ja, pt-BR, zh-CN`
* Provides [template-ready configuration files](https://github.com/mbto/maxmind-geoip2-csv2sql-converter/tree/master/src/main/resources) for `MySQL 8/PostgreSQL 13/Microsoft SQL Server 2019` and template engine with simple syntax for build DDL/DML. For custom DBMS, you can write a template yourself.
* Win/Unix distribution

#### Requirements:
* Java 11+ at [adoptopenjdk.net](https://adoptopenjdk.net/releases.html?variant=openjdk11&jvmVariant=hotspot) or [github.com/raphw/raphw.github.io](https://github.com/raphw/raphw.github.io/blob/master/openjdk/openjdk.csv) or [oracle.com/java](https://www.oracle.com/java/technologies/javase-downloads.html)

#### Examples:
* https://github.com/mbto/maxmind-geoip2-csv2sql-converter/wiki/Examples

#### Downloads:
* https://github.com/mbto/maxmind-geoip2-csv2sql-converter/releases

#### Usage:
* https://github.com/mbto/maxmind-geoip2-csv2sql-converter/wiki/Usage

#### Compile & Build:
* Requirements:
    * Gradle 5.4+
* With tests:
    * gradlew.bat build
* Without tests:
    * gradlew.bat build -x test
