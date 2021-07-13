package com.github.mbto.maxmind.geoip2.csv2sql.streaming.converters;

import com.github.jgonian.ipmath.AbstractIpRange;
import com.github.jgonian.ipmath.Ipv4Range;
import com.github.jgonian.ipmath.Ipv6Range;
import com.github.jgonian.ipmath.Range;
import com.github.mbto.maxmind.geoip2.csv2sql.Registry;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.BRWrapper;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.Location.IPBlock;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.Message;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.SplitterIntoFiles;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.writers.Writer;
import com.github.mbto.maxmind.geoip2.csv2sql.utils.CsvHolder;

import java.nio.file.Path;
import java.util.Arrays;
import java.util.Map;
import java.util.concurrent.FutureTask;
import java.util.function.Function;

import static com.github.mbto.maxmind.geoip2.csv2sql.streaming.Event.WRITE;
import static com.github.mbto.maxmind.geoip2.csv2sql.streaming.converters.LocationsConverter.geonameIdsWithEmptyCountryIsoCode;
import static com.github.mbto.maxmind.geoip2.csv2sql.streaming.converters.LocationsConverter.ignoredGeonameIds;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.ProjectUtils.*;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder.ParseUtils.StringUtils.split2;

/**
 * 1 thread reads GeoLite2-(Country|City)-Blocks-(IPv4|IPv6).csv file and fill messageQueue
 */
public class IPBlockConverter extends AbstractConverter {
    private final String[] priorityGeonameIdGroupNames;

    public IPBlockConverter(Registry registry, String dataType, int queueCapacity) {
        super(registry, dataType, queueCapacity);

        String priorityGeonameIdGroupNamesRaw = registry.getFromExportSection("ipblocks_priority_geonameId_groupNames", true);
        if(!priorityGeonameIdGroupNamesRaw.isEmpty()) {
            String[] priorityGeonameIdGroupNames = split2(priorityGeonameIdGroupNamesRaw, ',', true, true);
            if(priorityGeonameIdGroupNames.length != 0)
                this.priorityGeonameIdGroupNames = priorityGeonameIdGroupNames;
            else
                this.priorityGeonameIdGroupNames = null;
        } else
            this.priorityGeonameIdGroupNames = null;
    }

    @Override
    public Void work() throws Throwable {
        BRWrapper brWrapper = null;
        try {
            Map<String, Integer> maxLengthByAllGroupName = registry.allocateMaxLengthsContainer(dataType);
            Path csvPath = registry.getScriptsPath().resolve(extractIPBlockFilename(registry, dataType));
            threadPrintln(System.out, "Started converting '" + csvPath.getFileName() + "'");
            brWrapper = new BRWrapper(csvPath);
            brWrapper.openIterator();
            if (!brWrapper.hasNext()) throw new IllegalStateException("Empty file '" + csvPath + "'");
            String[] groupNamesWithGeonameId = {
                    "geoname_id", "registered_country_geoname_id", "represented_country_geoname_id"
            };
            Function<String, AbstractIpRange<?, ?>> parseCidrFunc = dataType.contains("4")
                    ? Ipv4Range::parseCidr : Ipv6Range::parseCidr;
            Writer writer = new Writer(registry, dataType, messageQueue);
            writerT = new Thread(new FutureTask<>(writer));
            writerT.start();
            String groupNamesRaw = brWrapper.next();
            CsvHolder csvHolder = CsvHolder.make(groupNamesRaw);
            SplitterIntoFiles sif = writer.allocateSplitter();
            while (brWrapper.hasNext()) {
                String line = brWrapper.next();
                csvHolder.fillValues(line);
                if(!ignoredGeonameIds.isEmpty()) {
                    int geonameIdsCounter = 0;
                    for (String groupNameWithGeonameId : groupNamesWithGeonameId) {
                        String geonameIdStr = csvHolder.group(groupNameWithGeonameId);
                        if(geonameIdStr == null || geonameIdStr.isEmpty())
                            continue;
                        int geonameId = Integer.parseInt(geonameIdStr);
                        if(ignoredGeonameIds.contains(geonameId))
                            csvHolder.removeValue(groupNameWithGeonameId);
                        else
                            ++geonameIdsCounter;
                    }
                    if(geonameIdsCounter == 0) {
                        registry.incStats(sif.getDataType() /*== dataType*/ + "_ignored");
                        continue;
                    }
                }
                IPBlock ipBlock = new IPBlock(csvHolder, parseCidrFunc);
                ipBlock.setPriorityGeonameId(findPriorityGeonameId(csvHolder));
                for (Map.Entry<String, String> entry : ipBlock.getValues().entrySet()) {
                    String value = entry.getValue();
                    if (value == null)
                        continue;
                    String groupName = entry.getKey();
                    int len = value.length();
                    Integer currentLen = maxLengthByAllGroupName.get(groupName);
                    if (currentLen == null || len > currentLen)
                        maxLengthByAllGroupName.put(groupName, len);
                }
                writer.throwIfWriterUnavailable();
                messageQueue.put(new Message<>(ipBlock, WRITE, sif));
            }
            threadPrintln(System.out, "Finished converting '" + csvPath.getFileName() + "'");
            return null;
        } finally {
            if (brWrapper != null) {
                try {
                    brWrapper.close();
                } catch (Exception ignored) {}
            }
        }
    }

    private Integer findPriorityGeonameId(CsvHolder csvHolder) {
        if(priorityGeonameIdGroupNames == null)
            return null;
        Integer firstGeonameId = null;
        for (String groupName : priorityGeonameIdGroupNames) {
            String geonameIdStr = csvHolder.group(groupName);
            if(geonameIdStr == null || geonameIdStr.isEmpty())
                continue;
            int geonameId = Integer.parseInt(geonameIdStr);
            if(geonameIdsWithEmptyCountryIsoCode.contains(geonameId)) {
                if(firstGeonameId == null)
                    firstGeonameId = geonameId;
                continue;
            }
            return geonameId;
        }
        if(firstGeonameId != null)
            return firstGeonameId;
        throw new IllegalStateException("Failed to determine priority geoname_id by group names "
                + Arrays.toString(priorityGeonameIdGroupNames)
                + " from " + csvHolder.getValueByGroupName());
    }
}