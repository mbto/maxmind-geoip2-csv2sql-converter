package com.github.mbto.maxmind.geoip2.csv2sql.utils;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import java.util.stream.Collectors;

import static com.github.mbto.maxmind.geoip2.csv2sql.utils.ProjectUtils.resolveConfigDirectory;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder.ParseUtils.StringUtils.split2;
import static java.nio.charset.StandardCharsets.UTF_8;

public abstract class EmojiHolder {
    private static final Map<String, String> emojiByCountryIsoCode;

    static {
        Path dirPath = resolveConfigDirectory();
        try (var br = Files.newBufferedReader(dirPath.resolve("emoji.txt"), UTF_8)) {
            emojiByCountryIsoCode = br.lines()
                    .map(str -> str.replace(" {2,}", " ").trim())
                    .filter(str -> !str.isEmpty())
                    .map(str -> split2(str, ' ', true, true))
                    .filter(rawEmoji -> rawEmoji.length == 2)
                    .collect(Collectors.toUnmodifiableMap(
                            rawEmoji -> rawEmoji[0],
                            rawEmoji -> rawEmoji[1],
                            (v1, v2) -> {
                                throw new UnsupportedOperationException("Failed building emoji map, due dublicate ISO country codes with values '" + v1 + "' '" + v2 + "'");
                            }));
        } catch (Exception e) {
            System.err.println("Unable to read /emoji.txt file from '" + dirPath + "'");
            e.printStackTrace();
            System.exit(1);
            throw new RuntimeException(e); // compiler needs failed initialization "final" field
        }
    }

    public static String get(String countryIsoCode) {
        if (countryIsoCode == null)
            return emojiByCountryIsoCode.get("default");

        String emoji = emojiByCountryIsoCode.get(countryIsoCode);
        return emoji != null ? emoji : emojiByCountryIsoCode.get("default");
    }

    public static int size() {
        return emojiByCountryIsoCode.size();
    }
}