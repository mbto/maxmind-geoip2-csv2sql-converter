package com.github.mbto.maxmind.geoip2.csv2sql;

import com.beust.jcommander.DynamicParameter;
import com.beust.jcommander.Parameter;
import com.github.mbto.maxmind.geoip2.csv2sql.utils.ProjectUtils;
import com.github.mbto.maxmind.geoip2.csv2sql.utils.jcommander.IPVersionValidator;
import com.github.mbto.maxmind.geoip2.csv2sql.utils.jcommander.LocaleConverter;
import com.github.mbto.maxmind.geoip2.csv2sql.utils.jcommander.LocaleValidator;
import lombok.Getter;
import lombok.Setter;
import lombok.ToString;

import java.nio.file.Path;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

import static com.github.mbto.maxmind.geoip2.csv2sql.utils.Constants.CONFIG_NAME_FORMAT;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.Constants.DEFAULT_ARCHIVE_NAME;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.ProjectUtils.MBtoBytes;

@Getter
@Setter
@ToString
public class Args {
    private static final String maxMindApiURI = "https://download.maxmind.com/app/geoip_download?edition_id=${.editionId}&license_key=${.args.licenseKey}&suffix=zip";
    @Parameter(names = "-s", order = 1,
            description = "Source zip archive at filesystem or http(s) request to MaxMind API URI or other http(s) source")
    private String sourceArchiveURI = maxMindApiURI;

    @Parameter(names = "-od", order = 2,
            description = "Output directory path")
    private Path outputDirPath = ProjectUtils.resolveConfigDirectory().resolve("converted");

    @Parameter(names = "-oa", order = 3,
            description = "Output archive name. Set empty \"\" for disable archiving")
    private String outputArchiveName = DEFAULT_ARCHIVE_NAME;

    @Parameter(names = "-k", order = 4,
            description = "License key for MaxMind API. Free at https://support.maxmind.com/hc/en-us/articles/4407111582235-Generate-a-License-Key")
    private String licenseKey;

    @Parameter(names = "-c", order = 5, required = true,
            description = "Config relative or absolute path: GeoLite2-Country-CSV.mysql.default.ini or GeoLite2-City-CSV.mysql.default.ini\n" +
            "      or your custom formatted " + CONFIG_NAME_FORMAT)
    private String configPathRaw;

    @Parameter(names = "-i", order = 6, validateValueWith = IPVersionValidator.class,
            description = "IP Blocks version: 4 or 6 or 4,6")
    private List<Integer> ipVersions = Arrays.asList(4, 6);

    /**
     * If no default value present: LocaleConverter at each string then LocaleValidator at List<Locale>
     * If default value present: LocaleValidator at List<Locale> then LocaleConverter at each string then LocaleValidator at List<Locale>
     */
    @Parameter(names = "-l", order = 7, validateValueWith = LocaleValidator.class,
            converter = LocaleConverter.class,
            description = "Locale codes of location files. Example: en,ru,de,es,fr,ja,pt-BR,zh-CN")
    private List<Locale> localeCodes = Arrays.stream("en,ru,de,es,fr,ja,pt-BR,zh-CN".split(","))
            .map(Locale::new)
            .collect(Collectors.toList());

    @DynamicParameter(names = "-LV", order = 8, description = "Filter values from location files by group name with regex:\n" +
            "      Example - for both GeoLite2-Country-CSV and GeoLite2-City-CSV editions:\n" +
            "      -LVgeoname_id=.*777.* -LVlocale_code=en,ru,de,es,fr\n" +
            "      -LVcontinent_code=EU,NA,OC -LVcontinent_name=Europe|Africa,Asia\n" +
            "      -LVcountry_iso_code=AU,NZ,GB,IE,US,CA,CY\n" +
            "      -LVcountry_name=Austr.*,Zealand$,^United,Ireland,Canada|Cyprus\n" +
            "      -LVis_in_european_union=0|1\n" +
            "      At GeoLite2-City-CSV edition available filter by city_name and other group names:\n" +
            "      -LVsubdivision_1_iso_code=WO|JD|NU|GE|A.* -LVsubdivision_1_name=.*O.*\n" +
            "      -LVsubdivision_2_iso_code=.* -LVsubdivision_2_name=.*A.*\n" +
            "      -LVcity_name=Newport,^Clinton$|^Richmond$,\"Mandria, Paphos\",^Salem\n" +
            "      -LVmetro_code=.* -LVtime_zone=.*/.*E.*"
    )
    private Map<String, String> allowedLocationValuesRawByGroupName = new LinkedHashMap<>();

    @Parameter(names = "-mm", order = 9,
            description = "Max megabytes count per file in generated files")
    private int megaBytesCountPerFile = 64;

    @Parameter(names = "-mr", order = 10, description = "Max records (values blocks) per line in generated files")
    private int recordsPerLine = 100;

    @Parameter(names = "-dc", order = 11, arity = 1,
            description = "Delete extracted *.csv source files after converting")
    private Boolean deleteCSVs = true;

    @Parameter(names = "-ds", order = 12, arity = 1,
            description = "Delete generated *.sql and other script files after converting")
    private Boolean deleteScripts = false;

    @Getter
    @Setter
    public static class Locale {
        private final String code;
        private final Map<String, Integer> maxLengthByGroupName = new LinkedHashMap<>();

        public Locale(String code) {
            this.code = code;
        }

        /**
         * Invokes from template
         */
        public String getMaxLengthOrDefault(String groupName, int defaultValue) {
            return "" + maxLengthByGroupName.getOrDefault(groupName, defaultValue);
        }

        @Override
        public String toString() {
            return code;
        }
    }

    public long getBytesCountPerFile() {
        return MBtoBytes(megaBytesCountPerFile);
    }
}