package com.github.mbto.maxmind.geoip2.csv2sql.utils;

import lombok.Getter;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Predicate;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class CsvHolder {
    /**
     * https://stackoverflow.com/a/42535295
     */
    public static final Pattern csvPattern = Pattern.compile("(?<quoted>(?<=,\"|^\")(?:\"\"|[\\w\\W]*?)*(?=\",|\"$))|(?<normal>(?<=,(?!\")|^(?!\"))[^,]*?(?=(?<!\")$|(?<!\"),))|(?<eol>\\r\\n|\\n)");
    @Getter
    private final List<String> headers;
    @Getter
    private final Map<String, String> valueByGroupName = new LinkedHashMap<>();

    private CsvHolder(List<String> headers) {
        this.headers = headers;
    }

    public static CsvHolder make(String line) {
        return new CsvHolder(extract(line));
    }

    public static List<String> extract(String line) {
        Matcher matcher = csvPattern.matcher(line);
        List<String> values = new ArrayList<>();
        while (matcher.find()) {
            String value = matcher.group(0);
            values.add(value.isEmpty() ? null : value);
        }
        return values;
    }

    public void fillValues(String line) {
        List<String> values = extract(line);
        int headersSize = headers.size();
        int valuesSize = values.size();

        if (headersSize != valuesSize)
            throw new IllegalStateException("Failed check values sizes. Expected " + headersSize + ", actual " + valuesSize);

        valueByGroupName.clear();

        for (int i = 0; i < headersSize; i++) {
            String header = headers.get(i);
            String value = values.get(i);
            valueByGroupName.put(header, value);
        }
    }

    public String group(String groupName) {
        return valueByGroupName.get(groupName);
    }

    public String removeValue(String groupName) {
        return valueByGroupName.remove(groupName);
    }

    public Map<String, String> copyValueByGroupNameMap(Predicate<Map.Entry<String, String>> filterFunc) {
        return valueByGroupName.entrySet()
                .stream()
                .filter(filterFunc)
                .collect(LinkedHashMap::new,
                        (map, entry) -> map.put(entry.getKey(), entry.getValue()),
                        LinkedHashMap::putAll);
    }
}