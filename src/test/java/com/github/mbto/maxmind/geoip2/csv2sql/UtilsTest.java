package com.github.mbto.maxmind.geoip2.csv2sql;

import com.github.jgonian.ipmath.Ipv4;
import com.github.jgonian.ipmath.Ipv4Range;
import com.github.jgonian.ipmath.Ipv6;
import com.github.jgonian.ipmath.Ipv6Range;
import com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder.Template;
import org.apache.commons.compress.archivers.ArchiveEntry;
import org.apache.commons.compress.archivers.zip.ZipArchiveInputStream;
import org.apache.commons.compress.utils.IOUtils;
import org.junit.Assert;
import org.junit.Test;

import java.io.*;
import java.math.BigInteger;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

import static com.github.mbto.maxmind.geoip2.csv2sql.Constants.archiveDate;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder.ParseUtils.StringUtils.split2;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder.ParseUtils.splitWithoutBrackets;
import static java.nio.charset.StandardCharsets.UTF_8;
import static org.junit.Assert.assertEquals;

public class UtilsTest {
    @Test
    public void testIPv4Limits() {
        String[] actualA = {
                "0.0.0.0", "0.0.0.1", "0.0.0.255", "0.0.1.0", "0.0.255.0",
                "0.1.0.0", "0.255.0.0", "1.0.0.0", "255.0.0.0", "255.255.255.255",
                "255.255.0.255", "255.0.255.255", "0.255.255.255", "0.255.0.0", "0.0.255.0",
                "192.168.1.2", "0.255.255.0",
        };
        long[] expectedN = {
                0, 1, 255, 256, 65280, 65536,
                16711680, 16777216, 4278190080L, 4294967295L, 4294902015L,
                4278255615L, 16777215, 16711680, 65280, 3232235778L, 16776960,
        };
        for (int i = 0; i < actualA.length; i++) {
            assertEquals(Ipv4.parse(actualA[i]), Ipv4.of(expectedN[i]));
        }
    }

    @Test
    public void testIpv4Range() throws Exception {
/* network,network_start_ip,network_last_ip,network_start_integer,network_last_integer,network_start_hex,network_last_hex,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider
   1.0.0.0/24,1.0.0.0,1.0.0.255,16777216,16777471,1000000,10000ff,2077456,2077456,,0,0
   1.0.1.0/24,1.0.1.0,1.0.1.255,16777472,16777727,1000100,10001ff,1814991,1814991,,0,0 */
        for (String line : extractDataLines("country_ipv4.csv", 1)) {
            String[] data = split2(line, ',', true, true);

            Ipv4Range ipv4Range = Ipv4Range.parseCidr(data[0]);
            assertEquals(ipv4Range.start().toString(), Ipv4.parse(data[1]).toString());
            assertEquals(ipv4Range.end().toString(), Ipv4.parse(data[2]).toString());
            assertEquals(ipv4Range.start(), Ipv4.of(Long.valueOf(data[3])));
            assertEquals(ipv4Range.end(), Ipv4.of(Long.valueOf(data[4])));
        }
    }

    @Test
    public void testIpv6Range() throws Exception {
/* network,network_start_ip,network_last_ip,network_start_integer,network_last_integer,network_start_hex,network_last_hex,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider
   2a7:1c44:39f3:1b::/64,2a7:1c44:39f3:1b::,2a7:1c44:39f3:1b:ffff:ffff:ffff:ffff,3526142879863516208564147688489091072,3526142879863516227010891762198642687,2a71c4439f3001b0000000000000000,2a71c4439f3001bffffffffffffffff,2658434,,,0,0
   2000:db8::/32,2000:db8::,2000:db8:ffff:ffff:ffff:ffff:ffff:ffff,42535574114424058029275454455324606464,42535574193652220543539792048868556799,20000db8000000000000000000000000,20000db8ffffffffffffffffffffffff,6252001,,,0,0
   2001:200::/32,2001:200::,2001:200:ffff:ffff:ffff:ffff:ffff:ffff,42540528726795050063891204319802818560,42540528806023212578155541913346768895,20010200000000000000000000000000,20010200ffffffffffffffffffffffff,1861060,1861060,,0,0 */
        for (String line : extractDataLines("country_ipv6.csv", 1)) {
            String[] data = split2(line, ',', true, true);

            Ipv6Range ipv6Range = Ipv6Range.parseCidr(data[0]);
            assertEquals(ipv6Range.start().toString(), Ipv6.parse(data[1]).toString());
            assertEquals(ipv6Range.end().toString(), Ipv6.parse(data[2]).toString());
            assertEquals(ipv6Range.start(), Ipv6.of(new BigInteger(data[3])));
            assertEquals(ipv6Range.end(), Ipv6.of(new BigInteger(data[4])));
        }
    }

    /**
     * https://github.com/maxmind/geoip2-csv-converter
     * C:\GeoLite2\geoip2-csv-converter.exe -block-file C:\GeoLite2\GeoLite2-Country-Blocks-IPv4.csv -output-file C:\GeoLite2\country_ipv4.csv -include-cidr -include-range -include-integer-range -include-hex-range
     * C:\GeoLite2\geoip2-csv-converter.exe -block-file C:\GeoLite2\GeoLite2-Country-Blocks-IPv6.csv -output-file C:\GeoLite2\country_ipv6.csv -include-cidr -include-range -include-integer-range -include-hex-range
     */
    private List<String> extractDataLines(String dataFilename, @SuppressWarnings("SameParameterValue") int skipLinesCount) throws Exception {
        String expandedArchiveName = "ipv4_ipv6_expanded_from_GeoLite2-Country-CSV_" + archiveDate + ".zip";
        //noinspection ConstantConditions
        Path testDataPath = Paths.get(UtilsTest.class.getResource("/" + expandedArchiveName).toURI());
        try(var zais = new ZipArchiveInputStream(new BufferedInputStream(Files.newInputStream(testDataPath)))) {
            ArchiveEntry entry;
            while ((entry = zais.getNextEntry()) != null) {
                if (!zais.canReadEntryData(entry) || entry.isDirectory()) {
                    continue;
                }

                String entryName = entry.getName();
                int slash = entryName.lastIndexOf("/");
                if (slash > -1)
                    entryName = entryName.substring(slash + 1);

                if(!entryName.equals(dataFilename))
                    continue;

                ByteArrayOutputStream baos = new ByteArrayOutputStream();
                IOUtils.copy(zais, baos);
                baos.flush();
                return new BufferedReader(new InputStreamReader(new ByteArrayInputStream(baos.toByteArray()), UTF_8))
                        .lines()
                        .skip(skipLinesCount)
                        .collect(Collectors.toList());
            }
        }
        throw new IllegalArgumentException("CSV files not founded");
    }

    @Test
    public void testSplitters() {
        for (String placeholdersData : placeholdersDatas) {
            String[] parts1 = placeholdersData.split("\\.");
            String[] parts2 = splitWithoutBrackets(placeholdersData, '.', false, false);
            String[] parts3 = split2(placeholdersData, '.', false, false);
            Assert.assertArrayEquals(parts1, parts2);
            Assert.assertArrayEquals(parts1, parts3);
        }
    }
    static String[] placeholdersDatas = new String[] {
            "localeValues",
            "localeValues.keySet()",
            "localeValues.keySet().toString()",
            "localeValues.keySet().toString().hashCode()",
            "localeValues.keySet().size()",
            "localeValues.keySet()..toString()",
            "localeValues.keySet()..toString().hashCode()",
            "localeValues.keySet()..toString()..hashCode()",
            "localeValues.values()",
            "localeValues.values().toString()",
            "localeValues.values()..toString()",
            "localeValues.values()..get(\"country_name\")",
            "localeValues.values()..FIELD0",
            "localeValues.values()..field1.toString()",
            "localeValues.values()..field1",
            "localeValues.values()..field1_1.toString()",
            "localeValues.values()..field1_1",
            "localeValues.values().hashCode()",
            "localeValues.values()..hashCode()",
            "localeValues.values().size()",
            "localeValues.values()..someList",
            "localeValues.values()..someList.hashCode()",
            "localeValues.values()..someList..hashCode()",
            "localeValues.values()..someList.toString()",
            "localeValues.values()..someList..toString()",
            "localeValues.size()",
            "localeValues.size().hashCode()",
            "emoji",
            "emoji.asd",
            "emoji.length()",
            "emoji.toString()",
            "emoji.hashCode()",
            "emoji..hashCode()",
            "emoji.size()",
            "emoji..someList",
            "emoji..someList.hashCode()",
            "emoji..someList..hashCode()",
            "emoji..someList.toString()",
            "emoji..someList..toString()",
            "emoji.size()",
            "emoji..size()",
            "emoji.size().hashCode()",
            // exceptions expected:
            "ipBlocks",
            "ipBlocks.toString()",
            "ipBlocks..toString()",
            "ipBlocks.hashCode()",
            "ipBlocks..hashCode()",
            "ipBlocks.size()",
            "ipBlocks..someList",
            "ipBlocks..someList.hashCode()",
            "ipBlocks..someList..hashCode()",
            "ipBlocks..someList.toString()",
            "ipBlocks..someList..toString()",
            "ipBlocks.size()",
            "ipBlocks..size()",
            "ipBlocks.size().hashCode()",
            "isoCode.toLowerCase().toUpperCase().toLowerCase().toUpperCase().length()",
            "isoCode.toLowerCase().toUpperCase().toLowerCase().toUpperCase().hashCode()",
            "isoCode.toLowerCase().toUpperCase().toLowerCase().toUpperCase()",
            "isoCode.toLowerCase().toUpperCase().toLowerCase().toUpperCase().toLowerCase()",
            "isoCode",
            "geonameId",
    };

    @Test
    public void testSplitWithoutBrackets() {
        Assert.assertEquals(4, splitWithoutBrackets("...", '.', false, false).length);
        Assert.assertEquals(3, splitWithoutBrackets("..", '.', false, false).length);
        Assert.assertEquals(2, splitWithoutBrackets(".", '.', false, false).length);
        Assert.assertEquals(1, splitWithoutBrackets("", '.', false, false).length);
        Assert.assertEquals(4, splitWithoutBrackets("a...", '.', false, false).length);
        Assert.assertEquals(3, splitWithoutBrackets("a..", '.', false, false).length);
        Assert.assertEquals(2, splitWithoutBrackets("a.", '.', false, false).length);
        Assert.assertEquals(1, splitWithoutBrackets("a", '.', false, false).length);
        Assert.assertEquals(4, splitWithoutBrackets("...a", '.', false, false).length);
        Assert.assertEquals(3, splitWithoutBrackets("..a", '.', false, false).length);
        Assert.assertEquals(2, splitWithoutBrackets(".a", '.', false, false).length);
    }
    @Test
    public void testTemplateEngine() {
        Registry registry = new Registry();
        Args args = registry.getArgs();
//        args.setIpVersions(Arrays.asList(4, 6));
//        args.setMegaBytesCountPerFile(4);

        Args.Locale enLocale = new Args.Locale("en");
        int enLocaleHashcode = enLocale.hashCode(); // if test runs in gradle task - hashCode may be another
        System.out.println("enLocale.hashCode()=" + enLocaleHashcode + "\n");
        args.setLocaleCodes(Arrays.asList(enLocale, new Args.Locale("ru"), new Args.Locale("de")));

        registry.allocateMaxLengthsContainer("location").put("geoname_id", 123456);
        registry.allocateMaxLengthsContainer("location").put("subdivision_2_iso_code", 99);

        System.out.println("Test implicit object context");
        String[][] templates = new String[][] {
                { "enLocale.getCode(): ${.code}", "enLocale.getCode(): en" },
                { "enLocale.toString(): ${.toString()}", "enLocale.toString(): en"},
                { "enLocale.hashCode(): ${.hashCode()}", "enLocale.hashCode(): " + enLocaleHashcode},
                { "enLocale.toString().hashCode(): ${.toString().hashCode()}" , "enLocale.toString().hashCode(): 3241"} };
        runResolve(templates, enLocale);

        System.out.println("Test object context");
        templates = new String[][] {
                { "Locale.getCode(): ${locale.code}", "Locale.getCode(): en" },
                { "locale: ${locale}", "locale: en" },
                { "Locale.toString(): ${locale.toString()}", "Locale.toString(): en" },
                { "Locale.hashCode(): ${locale.hashCode()}", "Locale.hashCode(): " + enLocaleHashcode},
                { "Locale.toString().hashCode(): ${locale.toString().hashCode()}", "Locale.toString().hashCode(): 3241" } };
        runResolve(templates, Map.of("locale", enLocale));

        System.out.println("Test map context");
        templates = new String[][] {
                { "locationMaxLengths: ${locationMaxLengths}", "locationMaxLengths: {geoname_id=123456, subdivision_2_iso_code=99}" },
                { "One toString(): ${locationMaxLengths.toString()}", "One toString(): {geoname_id=123456, subdivision_2_iso_code=99}" },
                { "One value 123456: ${locationMaxLengths.get(\"geoname_id\")}", "One value 123456: 123456" },
                { "One value 99: ${locationMaxLengths.get(\"subdivision_2_iso_code\")}", "One value 99: 99" },
                { "First key from keySet(): ${locationMaxLengths.keySet()}", "First key from keySet(): geoname_id" },
                { "First value from values(): ${locationMaxLengths.values()}", "First value from values(): 123456" },
                { "All keys from keySet(): #{forEach{<${locationMaxLengths.keySet()}>} Separator{,}}", "All keys from keySet(): <geoname_id>,<subdivision_2_iso_code>" },
                { "All values from values(): #{forEach{<${locationMaxLengths.values()}>} Separator{,}}", "All values from values(): <123456>,<99>" },
                { "All lengths of keys from keySet(): #{forEach{<${locationMaxLengths.keySet()..length()}>} Separator{,}}", "All lengths of keys from keySet(): <10>,<22>" },
                { "All hashCodes of keys from keySet(): #{forEach{<${locationMaxLengths.keySet()..hashCode()}>} Separator{,}}", "All hashCodes of keys from keySet(): <970042078>,<1582801766>" },
                { "Size of keySet() 2: ${locationMaxLengths.keySet().size()}", "Size of keySet() 2: 2" },
                { "Size of keySet() 2: #{forEach{<${locationMaxLengths.keySet().size()}>} Separator{,}}", "Size of keySet() 2: <2>" },
                { "One mutate key+length+keySet.size: #{forEach{${locationMaxLengths.keySet()} ${locationMaxLengths.keySet()..length()} <${locationMaxLengths.keySet().size()}>} Separator{,}}",
                        "One mutate key+length+keySet.size: geoname_id 10 <2>,subdivision_2_iso_code 22 <2>" } };
        runResolve(templates, Map.of("locationMaxLengths", registry.allocateMaxLengthsContainer("location")));

        System.out.println("Test list context");
        templates = new String[][] {
                { "One toString() from first object: ${locales}", "One toString() from first object: en" },
                { "All toString() from all objects: #{forEach{<${locales}>} Separator{,}}",
                        "All toString() from all objects: <en>,<ru>,<de>" },
                { "All toString() from all objects: #{forEach{<${locales..toString()}>} Separator{,}}",
                        "All toString() from all objects: <en>,<ru>,<de>" },
                { "One toString(): ${locales.toString()}", "One toString(): [en, ru, de]" },
                { "All codes: #{forEach{<${locales..code}>} Separator{,}}", "All codes: <en>,<ru>,<de>" },
                { "First code: ${locales..code}", "First code: en" },
                { "One size: #{forEach{<${locales.size()}>} Separator{,}}", "One size: <3>" },
                { "One size: ${locales.size()}", "One size: 3" },
                { "One mutate from 2 contexts(collections+collections) code+context.size: #{forEach{${locales..code} <${locales.size()}>} Separator{,}}",
                        "One mutate from 2 contexts(collections+collections) code+context.size: en <3>,ru <3>,de <3>" },
                { "One mutate from 2 contexts(map+collection) key+length+keySet.size+code+context.size: #{forEach{${locationMaxLengths.keySet()} ${locationMaxLengths.keySet()..length()} <${locationMaxLengths.keySet().size()}> ${locales..code} <${locales.size()}>} Separator{,}}",
                        "One mutate from 2 contexts(map+collection) key+length+keySet.size+code+context.size: geoname_id 10 <2> en <3>,subdivision_2_iso_code 22 <2> ru <3>,geoname_id 10 <2> de <3>" } };
        runResolve(templates, Map.of("locales", registry.getArgs().getLocaleCodes(), "locationMaxLengths", registry.allocateMaxLengthsContainer("location")));

        System.out.println("Test implicit List context");
        templates = new String[][] {
                { "All codes from implicit context(collection): #{forEach{<${..code}>} Separator{,}}", "All codes from implicit context(collection): <en>,<ru>,<de>" },
                { "First code from implicit context(collection): ${..code}", "First code from implicit context(collection): en" },
                { "One size of implicit context(collection): ${.size()}", "One size of implicit context(collection): 3" } };
        runResolve(templates, registry.getArgs().getLocaleCodes());

        System.out.println("Test implicit empty List context");
        args.setLocaleCodes(Collections.emptyList());
        templates = new String[][] {
                { "No codes from implicit context(collection): #{forEach{<${..code}>} Separator{,}}", "No codes from implicit context(collection): <>" },
                { "No forEach from implicit context(collection): #{forEach{<${..code}>} Separator{,} Disable{EmptyCollection}}", "No forEach from implicit context(collection): " },
                { "Exception expected: First code from implicit context(collection): ${..code}", null },
                { "One size of implicit context(collection): ${.size()}", "One size of implicit context(collection): 0" } };
        runResolve(templates, registry.getArgs().getLocaleCodes());
    }
    private void runResolve(String[][] templates, Map<String, Object> contextByAlias) {
        runResolve(templates, null, contextByAlias);
    }
    private void runResolve(String[][] templates, Object implicitContext) {
        runResolve(templates, implicitContext, null);
    }
    private void runResolve(String[][] templates, Object implicitContext, Map<String, Object> contextByAlias) {
        for (String[] templateData : templates) {
            try {
                Template template = Template.compile(templateData[0]);
                if(implicitContext != null)
                    template.putContext(implicitContext);
                if(contextByAlias != null)
                    template.putContext(contextByAlias);

                Assert.assertEquals(templateData[1], template.resolve());
            } catch (Exception e) {
//                System.err.println("Unresolved: '" + templateData[0] + "'");
//                e.printStackTrace();
                Assert.assertNull(templateData[1]);
            }
        }
    }
    // not actual at now, but leaved template
    /*@Test
    public void testReflectionUtils() {
        String[] locationsData = {
                "geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union",
                "2017370,en,EU,Europe,RU,Russia,0",
                "2017370,ru,EU,\"Европа\",RU,\"Россия\",0",
                "2017370,de,EU,Europa,RU,Russland,0"};
        CsvHolder csvHolder = null;
        Location location = null;
        for (int i = 0; i < locationsData.length; i++) {
            String line = locationsData[i];
            if(i == 0) {
                csvHolder = CsvHolder.make(line);
                continue;
            }
            csvHolder.fillValues(line);
            if(location == null)
                location = new Location(csvHolder);
            location.aggregateValues(csvHolder);
        }
//        int[][] ranges = { {123123, 123100}, {234234, 234200}, {345345, 345000} };
//        for (int[] range : ranges) {
//            Location.IPBlock ipBlock = new Location.IPBlock(csvHolder, true);
//            ipBlock.getRanges().put("ipv4int", new Range<>(range[0], range[1]));
//            ipBlock.setPriorityGeonameId(Integer.parseInt(location.getValues().get("geoname_id")));
//        }

        for (String placeholder : placeholdersDatas) {
            try {
//                printResolvedObject(placeholder, ReflectionUtils.resolveObjectReferences(location, splitWithoutBrackets(placeholder, '.', false, false)));
            } catch (Exception e) {
                System.setErr(System.out);
                System.out.println("Unresolved: '" + placeholder + "'");
                e.printStackTrace();
                System.out.println("--------------");
            }
        }
    }

    @SuppressWarnings("rawtypes")
    private static void printResolvedObject(String placeholder, Object resolvedObject) {
        List<String> results = new ArrayList<>();
        if(resolvedObject == null)
            results.add("null");
        else if(resolvedObject instanceof Collection) {
            if(!((Collection<?>) resolvedObject).isEmpty()) {
                Object firstValue = ((Collection<?>) resolvedObject).iterator().next();
                Collection<?> collected;
                if(firstValue instanceof Collection) {
                    collected = ((Collection<?>) resolvedObject).stream()
                            .flatMap(el -> ((Collection<?>) el).stream())
                            .collect(Collectors.toList());
                } else {
                    collected = ((Collection<?>) resolvedObject).stream()
                            .map(ProjectUtils::emptyIfNull)
                            .collect(Collectors.toList());
                }
                //noinspection unchecked
                results.addAll((Collection) collected);
            }
        } else
            results.add(resolvedObject.toString());

        System.out.println("placeholder=" + placeholder);
        //noinspection ConstantConditions
        System.out.println("resolvedObject=" + resolvedObject + " class=" + resolvedObject.getClass().getSimpleName());
        for (String value : results) {
            System.out.println("value=" + value);
        }
        System.out.println("--------");
    }*/
}