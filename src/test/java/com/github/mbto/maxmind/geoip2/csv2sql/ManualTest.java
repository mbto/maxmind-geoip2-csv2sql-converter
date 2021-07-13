package com.github.mbto.maxmind.geoip2.csv2sql;

import com.github.mbto.maxmind.geoip2.csv2sql.utils.IniFileParser;
import org.junit.Test;

import java.util.Arrays;
import java.util.stream.IntStream;

import static com.github.mbto.maxmind.geoip2.csv2sql.Constants.*;

/**
 * For manual testing in IntelliJ: add -PManualTestEnabled in Gradle tab "Run Configuration" -> "Arguments"
 * https://dev.mysql.com/doc/refman/8.0/en/integer-types.html
 * https://www.postgresql.org/docs/current/datatype-numeric.html
 * https://docs.microsoft.com/ru-ru/sql/t-sql/data-types/int-bigint-smallint-and-tinyint-transact-sql?view=sql-server-ver15
 */
public class ManualTest {
    @Test
    public void manualBuild1() throws Throwable {
        String editionId = "GeoLite2-Country-CSV";
//        String editionId = "GeoLite2-City-CSV";

        Application application = new Application();
        Registry registry = application.getRegistry();
        Args args = registry.getArgs();
        args.setOutputDirPath(integrationTestsDirPath);
//        args.setOutputArchiveName();
        args.setOutputArchiveName(resultArchiveName);
//        args.setOutputArchiveName("");
        args.setLicenseKey("some-key");
//        args.setConfigPathRaw("C://temp//" + buildMySQLConfigName(editionId));
//        args.setConfigPathRaw(buildMySQLConfigName(editionId));
        args.setConfigPathRaw(buildPostgreSQLConfigName(editionId));
//        args.setConfigPathRaw(buildMicrosoftSql2019ConfigName(editionId));
//        args.setIpVersions(Arrays.asList(4, 6));
//        args.setIpVersions(Arrays.asList(4));
        args.setIpVersions(Arrays.asList(6));
//        args.setLocaleCodes(Arrays.asList(new Args.Locale("en")));
//        args.setAllowedLocationValuesRawByGroupName(Map.of("continent_code", "EU,NA,OC"));
//        args.setBytesCountPerFile(350);
//        args.setMegaBytesCountPerFile(64);
//        args.setMegaBytesCountPerFile(5);
//        args.setRecordsPerLine(100);
//        args.setRecordsPerLine(1);
//        args.setApiURI();
        args.setDeleteCSVs(false);
        args.setDeleteScripts(false);
        registry.allocateRegistrySettings();
        args.setSourceArchiveURI(resourceTestsDirPath.resolve(buildArchiveName(registry.getEditionId())).toString());

        IniFileParser.parse(registry);
//        ((Map<String, String>) registry.getConfig().get("Export")).put("schema_name", "maxmind_city_only_v4");

        application.resolveOutputDirPath();
        application.grab();
        boolean extracted = application.extract();
//        boolean extracted = true;
        if (extracted) {
            application.convert();
            application.generate();
        }
        System.out.println("");
    }

    @Test
    public void manualBuild2() throws Throwable {
        String editionId = "GeoLite2-Country-CSV";
//        String editionId = "GeoLite2-City-CSV";
        String[] argsRaw = {
                "-s", resourceTestsDirPath.resolve(buildArchiveName(editionId)).toString(),
                "-od", buildIntegrationOutputDirPath(""),
                "-oa", "",//resultArchiveName,
                "-c", buildMySQLConfigName(editionId),
//                "-c", buildPostgreSQLConfigName(editionId),
//                "-i", "4",
                "-i", "6",
                "-l", "en",
//                "-i", "4,6",
//                "-l", "en,ru,de,es,fr,ja,pt-BR,zh-CN",
//                "-LVcontinent_code=EU,NA,OC",
//                "-LVcountry_iso_code=AU,NZ,GB,IE,US,CA,CY",
//                "-LVcountry_name=Austr.*,Zealand$,^United,Ireland,Canada|Cyprus",
//                "-LVcity_name=Newport,^Clinton$|^Richmond$,\"Mandria, Paphos\",^Salem$",
//                "-LVcountry_iso_code=A.",
//                "-LVcountry_iso_code=RU",
//                "-LVcountry_name=^United,Canada|Cyprus",
//                "-LVcity_name=Москва",
//                "-LVcity_name=^Москва$",
//                "-LVcity_name=asdasdads",
//                "-LVcity_name=\"Mandria, Paphos\"",
                "-mm", "32",
                "-dc", "false",
                "-ds", "false",
        };
        Application.run(argsRaw);
    }

    @Test
    public void manualBuildWithMaxmindApi() throws Throwable {
//        String editionId = "GeoLite2-City-CSV";
        String editionId = "GeoLite2-Country-CSV";
        String[] argsRaw = {
//                "-s", integrationTestsDirPath.resolve(buildArchiveName("GeoLite2-Country-CSV")).toString(),
                "-s", "R:\\test test\\maxmind-geoip2-csv2sql-converter-1.0\\bin\\converted\\GeoLite2-Country-CSV_20210629.zip",
//                "-od", buildIntegrationOutputDirPath(""),
                "-od", "R:\\test test\\maxmind-geoip2-csv2sql-converter-1.0\\bin\\converted",
                "-oa", resultArchiveName,
//                "-oa", "",
                "-c", buildMySQLConfigName(editionId),
//                "-c", buildPostgreSQLConfigName(editionId),
                "-k", IntStream.of(154,112,212,140,212,236,102,236,180,174,228,158,134,194,180,156)
                    .mapToObj(i -> (char) (i>>'\u0001'))
                    .reduce(new StringBuilder(), StringBuilder::append, StringBuilder::append)
                    .toString(),
//                "-dc", "false", "-ds", "true",
//                "-dc", "true", "-ds", "false",
//                "-dc", "true", "-ds", "true",
                "-dc", "false", "-ds", "false",
        };
        Application.run(argsRaw);
    }
}