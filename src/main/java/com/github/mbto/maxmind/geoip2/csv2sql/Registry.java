package com.github.mbto.maxmind.geoip2.csv2sql;

import com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder.Template;
import lombok.Getter;
import lombok.Setter;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static com.github.mbto.maxmind.geoip2.csv2sql.utils.Constants.CONFIG_NAME_FORMAT;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.CsvHolder.csvPattern;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.ProjectUtils.buildArgsSummary;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.ProjectUtils.resolveConfigDirectory;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder.ParseUtils.StringUtils.split2;

@Getter
public class Registry {
    private final Args args = new Args();
    /**
     * key    = value
     * Import = Map<key, value>
     * Export = Map<key, value>
     */
    private final Map<String, Object> config = new LinkedHashMap<>();
    private final Map<String, Template> templateByTemplateName = new LinkedHashMap<>();
    private final List<Path> csvSourcesPaths = new ArrayList<>();
    private final List<Path> generatedScriptsPaths = new ArrayList<>();
    private final Map<String, Map<String, Integer>> maxLengthsContainerByDataType = new HashMap<>();
    private final Map<String, Integer> stats = new TreeMap<>(String::compareTo);

    private Path configPath;
    private String editionId;
    private String DBMSname;
    private String configProfileName;
    private Map<String, List<Pattern>> allowedLocationValuesByGroupName;
    @Setter
    private Path archivePath;
    private Path scriptsPath;

    public void allocateRegistrySettings() {
        String configPathRaw = args.getConfigPathRaw();
        if(configPathRaw.contains("/") || configPathRaw.contains("\\"))
            configPath = Paths.get(configPathRaw);
        else
            configPath = resolveConfigDirectory().resolve(args.getConfigPathRaw());
        if(Files.notExists(configPath) || !Files.isRegularFile(configPath))
            throw new IllegalArgumentException("Invalid config path '" + configPath + "'");
        System.out.println("Resolved config path '" + configPath + "'");

        String[] configNameSplitted = split2(configPath.getFileName().toString(), '.', true, true);
        if (configNameSplitted.length != 4 || configNameSplitted[0].isBlank())
            throw new IllegalArgumentException("Invalid config name format, must be " + CONFIG_NAME_FORMAT);
        this.editionId = configNameSplitted[0];
        this.DBMSname = configNameSplitted[1];
        this.configProfileName = configNameSplitted[2];

        for (Map.Entry<String, String> entry : args.getAllowedLocationValuesRawByGroupName().entrySet()) {
            Matcher m = csvPattern.matcher(entry.getValue());
            List<Pattern> patterns = null;
            while (m.find()) {
                String value = m.group(0).trim();
                if(value.isEmpty())
                    continue;
                if(patterns == null)
                    patterns = new ArrayList<>();
                patterns.add(Pattern.compile(value, Pattern.MULTILINE | Pattern.CASE_INSENSITIVE | Pattern.UNICODE_CHARACTER_CLASS));
            }
            if(patterns != null) {
                if(allowedLocationValuesByGroupName == null)
                    allowedLocationValuesByGroupName = new LinkedHashMap<>();
                allowedLocationValuesByGroupName.put(entry.getKey(), patterns);
            }
        }
    }

    public void allocateScriptsPath() throws IOException {
//        String archiveNameWithoutDot = archivePath.getFileName().toString();
//        int dot = archiveNameWithoutDot.lastIndexOf('.');
//        archiveNameWithoutDot = dot > -1 ? archiveNameWithoutDot.substring(0, dot) : archiveNameWithoutDot;
        scriptsPath = args.getOutputDirPath();//.resolve(archiveNameWithoutDot);
        if (!Files.isDirectory(scriptsPath))
            Files.createDirectories(scriptsPath);
        System.out.println("Resolved scripts path '" + scriptsPath + "'");

        System.out.println(buildArgsSummary(this, true));
    }

    public String getFromImportSection(String settingsKey, boolean required) throws IllegalStateException, IllegalArgumentException {
        return getFromSection("Import", settingsKey, required);
    }

    public String getFromExportSection(String settingsKey, boolean required) throws IllegalStateException, IllegalArgumentException {
        return getFromSection("Export", settingsKey, required);
    }

    public String getFromSection(String sectionName, String settingsKey, boolean required) throws IllegalStateException, IllegalArgumentException {
        Map<String, String> valueBySettingsKey = (Map<String, String>) config.get(sectionName);
        if (valueBySettingsKey == null) {
            if(required)
                throw new IllegalStateException("Failed get settings from '" + sectionName + "' section");
            return null;
        }
        String value = valueBySettingsKey.get(settingsKey);
        if (value == null) {
            if(required)
                throw new IllegalArgumentException("Failed get value from '" + sectionName + "' section with key '" + settingsKey + "'");
            return null;
        }
        return value;
    }

    public Map<String, Integer> allocateMaxLengthsContainer(String dataType) {
        Map<String, Integer> container = maxLengthsContainerByDataType.get(dataType);
        //noinspection Java8MapApi
        if (container == null) {
            container = new LinkedHashMap<>();
            maxLengthsContainerByDataType.put(dataType, container);
        }
        return container;
    }

/*
select
    (select count(*) FROM maxmind_city.city) city,
    (select count(*) FROM maxmind_city.city cc where cc.name_en is null and cc.subdivision1_id is null) city_includes_which_unknown,
    (select count(*) from maxmind_city.country) country,
    (select count(*) from maxmind_city.country c where c.iso_code is null) country_includes_which_unknown,
    (select count(*) from maxmind_city.ipv4) ipv4,
    (select count(*) from maxmind_city.ipv6) ipv6,
    (select count(*) from maxmind_city.subdivision1) subdivision1,
    (select count(*) from maxmind_city.subdivision2) subdivision2,
    (select count(*) from maxmind_city.timezone) timezones;

select
    (select count(*) from maxmind_country.country) country,
    (select count(*) from maxmind_country.country c where c.iso_code is null) country_includes_which_unknown,
    (select count(*) from maxmind_country.ipv4) ipv4,
    (select count(*) from maxmind_country.ipv6) ipv6;
*/
    public void incStats(String key) {
        synchronized (stats) { // sync increment from 2 IPBlockConverter threads
            stats.put(key, stats.getOrDefault(key, 0) + 1);
        }
    }
}