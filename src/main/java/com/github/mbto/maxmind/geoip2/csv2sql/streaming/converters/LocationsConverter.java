package com.github.mbto.maxmind.geoip2.csv2sql.streaming.converters;

import com.github.mbto.maxmind.geoip2.csv2sql.Args.Locale;
import com.github.mbto.maxmind.geoip2.csv2sql.Registry;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.BRWrapper;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.Location;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.Location.LocationData;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.Message;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.SplitterIntoFiles;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.writers.Writer;
import com.github.mbto.maxmind.geoip2.csv2sql.utils.CsvHolder;

import java.nio.file.Path;
import java.util.*;
import java.util.concurrent.FutureTask;
import java.util.regex.Pattern;

import static com.github.mbto.maxmind.geoip2.csv2sql.streaming.Event.WRITE;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.ProjectUtils.extractLocationsFilenames;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.ProjectUtils.threadPrintln;

/**
 * 1 thread reads GeoLite2-(Country|City)-Locations-XXXX.csv files and fill messageQueue
 */
public class LocationsConverter extends AbstractConverter {
    public static final Set<Integer> geonameIdsWithEmptyCountryIsoCode = new HashSet<>();
    public static final Set<Integer> ignoredGeonameIds = new HashSet<>();
    private final boolean logUndefinedAllSubdivisionsAndCityName;

    public LocationsConverter(Registry registry, int queueCapacity) {
        super(registry, Location.class.getSimpleName().toLowerCase(), queueCapacity,
                Boolean.parseBoolean(registry.getFromExportSection("log_ignored_locations", true)));
        this.logUndefinedAllSubdivisionsAndCityName = Boolean.parseBoolean(registry.getFromExportSection("log_undefined_all_subdivisions_and_city_name", true));

        // multiple gradle tests not clean static variables
        geonameIdsWithEmptyCountryIsoCode.clear();
        ignoredGeonameIds.clear();
    }

    @Override
    public Void work() throws Throwable {
        List<BRWrapper> brWrappers = null;
        try {
            Map<String, Integer> maxLengthByAllGroupName = registry.allocateMaxLengthsContainer(dataType);
            List<Locale> locales = registry.getArgs().getLocaleCodes();
            String[] filenamesWithLocales = extractLocationsFilenames(registry);
            brWrappers = new ArrayList<>(filenamesWithLocales.length);
            CsvHolder csvHolder = null;
            for (String filenamesWithLocale : filenamesWithLocales) {
                Path csvPath = registry.getScriptsPath().resolve(filenamesWithLocale);
                threadPrintln(System.out, "Started converting '" + csvPath.getFileName() + "'");
                BRWrapper brWrapper = new BRWrapper(csvPath);
                brWrappers.add(brWrapper);
                brWrapper.openIterator();
                if (!brWrapper.hasNext())
                    throw new IllegalStateException("Empty file '" + csvPath + "'");
                String groupNamesRaw = brWrapper.next(); // 1'st line at all
                if (csvHolder == null)
                    csvHolder = CsvHolder.make(groupNamesRaw);
            }
            if (csvHolder == null) throw new IllegalStateException("Unable to define csvHolder, due empty locations_filenames template");
            Map<String, List<Pattern>> allowedLocationValuesByGroupName = registry.getAllowedLocationValuesByGroupName();
            boolean isCityEdition = csvHolder.getHeaders().contains("city_name");
            String dataTypeLabel = !isCityEdition ? "country" : "city";
            Writer writer = new Writer(registry, dataType, messageQueue);
            writerT = new Thread(new FutureTask<>(writer));
            writerT.start();
            outer: while (allHasNext(brWrappers)) {
                Location location = null;
                for (BRWrapper brWrapper : brWrappers) {
                    String line = brWrapper.next();
                    csvHolder.fillValues(line);
                    if (location == null)
                        location = new Location(csvHolder);
                    location.aggregateValues(csvHolder);
                }
                if(allowedLocationValuesByGroupName != null) {
                    for (Map.Entry<String, List<Pattern>> entry : allowedLocationValuesByGroupName.entrySet()) {
                        String filteredGroupName = entry.getKey(); // country_name
                        List<Pattern> allowedLocationValuePatterns = entry.getValue(); // Austr.*,Zealand$,^United,Ireland,Canada|Cyprus
                        //noinspection ConstantConditions
                        if(location.getLocaleValues()
                                .values()
                                .stream()
                                .noneMatch(locationData -> {
                                    String currentValue = locationData.get(filteredGroupName);
                                    return currentValue != null
                                            && allowedLocationValuePatterns.stream()
                                               .anyMatch(allowedLocationValuePattern -> allowedLocationValuePattern.matcher(currentValue).find());
                        })) {
                            int geoname_id = Integer.parseInt(location.getValues().get("geoname_id"));
                            ignoredGeonameIds.add(geoname_id);
                            if(logIgnored) {
                                threadPrintln(System.out, "Ignored '" + dataTypeLabel + "' in " + getConverterName()
                                        + " by filter '" + filteredGroupName + "'"
                                        + " only " + allowedLocationValuePatterns.toString()
                                        + " from " + csvHolder.getValueByGroupName());
                            }
                            registry.incStats(dataTypeLabel + " ignored");
                            continue outer;
                        }
                    }
                }
                for (Locale locale : locales) {
                    Map<String, Integer> maxLengthByGroupName = locale.getMaxLengthByGroupName();
                    //noinspection ConstantConditions
                    LocationData locationData = location.getLocaleValues().get(locale.getCode());
                    for (Map.Entry<String, String> entry : locationData.getValues().entrySet()) {
                        String value = entry.getValue();
                        if (value == null)
                            continue;
                        String groupName = entry.getKey();
                        int len = value.length();
                        Integer currentLen = maxLengthByGroupName.get(groupName);
                        if (currentLen == null || len > currentLen)
                            maxLengthByGroupName.put(groupName, len);
                        currentLen = maxLengthByAllGroupName.get(groupName);
                        if (currentLen == null || len > currentLen)
                            maxLengthByAllGroupName.put(groupName, len);
                    }
                }
                Message<Location> message = new Message<>(location, WRITE);

                //noinspection ConstantConditions
                Map<String, String> locationValues = location.getValues();

                SplitterIntoFiles sif = writer.allocateSplitter("country");
                String syntheticKey = locationValues.get("country_iso_code");
                if (syntheticKey == null) { // geoname_id with 6255147 6255148 with empty country_iso_code
                    syntheticKey = locationValues.get("geoname_id");
                    geonameIdsWithEmptyCountryIsoCode.add(Integer.parseInt(syntheticKey));
                    threadPrintln(System.out, "Informing: '" + sif.getDataType() + "' in " + getConverterName()
                            + " without country_iso_code from " + csvHolder.getValueByGroupName());
                    registry.incStats(sif.getDataType() + " includes which unknown");
                }

                Integer countryId = sif.getIdBySyntheticKey(syntheticKey);
                if (countryId == null) { // write only unique
                    countryId = sif.saveSyntheticKey(syntheticKey);
                    message.addSplitter(sif);
                }
                location.setId(sif.getDataType(), countryId);

                syntheticKey = locationValues.get("subdivision_1_iso_code");
                if (syntheticKey != null) {
                    syntheticKey = "" + countryId + syntheticKey;
                    sif = writer.allocateSplitter("subdivision1");
                    Integer id = sif.getIdBySyntheticKey(syntheticKey);
                    if (id == null) { // write only unique
                        id = sif.saveSyntheticKey(syntheticKey);
                        message.addSplitter(sif);
                    }
                    location.setId(sif.getDataType(), id);
                }
                syntheticKey = locationValues.get("subdivision_2_iso_code");
                if (syntheticKey != null) {
                    syntheticKey = "" + countryId + syntheticKey;
                    sif = writer.allocateSplitter("subdivision2");
                    Integer id = sif.getIdBySyntheticKey(syntheticKey);
                    if (id == null) { // write only unique
                        id = sif.saveSyntheticKey(syntheticKey);
                        message.addSplitter(sif);
                    }
                    location.setId(sif.getDataType(), id);
                }

                syntheticKey = locationValues.get("time_zone");
                if(syntheticKey != null) {
                    sif = writer.allocateSplitter("timezone");
                    Integer id = sif.getIdBySyntheticKey(syntheticKey);
                    if (id == null) { // write only unique
                        id = sif.saveSyntheticKey(syntheticKey);
                        message.addSplitter(sif);
                    }
                    location.setId(sif.getDataType(), id);
                }

                if (isCityEdition) {
                    sif = writer.allocateSplitter("city");
                    message.addSplitter(sif);
                    location.setId(sif.getDataType(), Integer.parseInt(location.getValues().get("geoname_id")));

                    if(location.getLocaleValues()
                            .values()
                            .stream()
                            .allMatch(locationData -> locationData
                                    .getValues()
                                    .entrySet()
                                    .stream()
                                    .filter(entry -> {
                                        String groupName = entry.getKey();
                                        /* "subdivision_1_iso_code" -> null
                                           "subdivision_1_name" -> null
                                           "subdivision_2_iso_code" -> null
                                           "subdivision_2_name" -> null
                                           "city_name" -> null */
                                        if(groupName.equals("city_name") || groupName.startsWith("subdivision")) {
                                            return entry.getValue() == null;
                                        }
                                        return false;
                                    }).count() == 5)) {
                        if(logUndefinedAllSubdivisionsAndCityName) {
                            threadPrintln(System.out, "Informing: '" + sif.getDataType() + "' in " + getConverterName()
                                    + " without subdivision_* and city_name from " + csvHolder.getValueByGroupName());
                        }
                        registry.incStats(sif.getDataType() + " includes which unknown");
                    }
                }

                writer.throwIfWriterUnavailable();
                messageQueue.put(message);
            }
            for (BRWrapper brWrapper : brWrappers) {
                threadPrintln(System.out, "Finished converting '" + brWrapper.getCsvPath().getFileName() + "'");
            }
            return null;
        } finally {
            if (brWrappers != null) {
                for (BRWrapper brWrapper : brWrappers) {
                    try {
                        brWrapper.close();
                    } catch (Exception ignored) {}
                }
            }
        }
    }

    private boolean allHasNext(List<BRWrapper> brWrappers) {
        for (BRWrapper brWrapper : brWrappers) {
            if (!brWrapper.hasNext())
                return false;
        }
        return true;
    }
}