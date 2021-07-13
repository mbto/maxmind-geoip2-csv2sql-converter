package com.github.mbto.maxmind.geoip2.csv2sql.utils;

import com.github.mbto.maxmind.geoip2.csv2sql.Registry;
import com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder.Template;

import java.io.BufferedReader;
import java.nio.file.Files;
import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static java.nio.charset.StandardCharsets.UTF_8;

public class IniFileParser {
    /**
     * https://regex101.com/r/WUETHI/1
     */
    @SuppressWarnings("RegExpRedundantEscape")
    private final Pattern sectionPattern = Pattern.compile("^[ \\t]*\\[[ \\t]*(?<section>.+?)[ \\t]*\\][ \\t]*$");
    /**
     * https://regex101.com/r/QxtBYm/1
     */
    private final Pattern internalSectionPattern = Pattern.compile("(?<key>[^ \\t\\r\\n\\[\\]]+):(?<value>[^ \\t\\r\\n\\[\\]]+)|(?<name>[^ \\t\\r\\n\\[\\]]+)");
    private final Pattern keyValuePattern = Pattern.compile("(?<key>.+?) *=(?<value>.*)");
    private final Map<Character, Character> replaceableCharByKey = new HashMap<>(5, 1f);
    private boolean mergeToPrevious;

    private IniFileParser() {
        replaceableCharByKey.put('n', '\n');
        replaceableCharByKey.put('r', '\r');
        replaceableCharByKey.put('t', '\t');
        replaceableCharByKey.put('[', '['); // if line syntax '^[section_name key:value]$' isn't section, but template value
        replaceableCharByKey.put('/', '/'); // http:/\/example.com -> http://example.com
    }

    public static void parse(Registry registry) throws Exception {
        new IniFileParser().load(registry);
    }

    private void load(Registry registry) throws Exception {
        Map<String, List<String>> templateContainerByTemplateName = new LinkedHashMap<>();
        try (BufferedReader br = Files.newBufferedReader(registry.getConfigPath(), UTF_8)) {
            Map<String, Object> config = registry.getConfig();
            Object container = null;
            String line;
            //noinspection UnusedLabel
            outer: while ((line = br.readLine()) != null) {
                line = line.trim();
                if (line.isEmpty())
                    continue;
                int commentPos = line.indexOf("//");
                if (commentPos > -1) {
                    line = line.substring(0, commentPos).trim();
                    if (line.isEmpty())
                        continue;
                }
                Matcher sectionMatcher = sectionPattern.matcher(line);
                if (!sectionMatcher.matches()) {
                    consume(container, line);
                    continue;
                }
                Matcher internalSectionMatcher = internalSectionPattern.matcher(sectionMatcher.group("section"));
                List<Section> sections = new ArrayList<>(3); // 3 = [Key:Value condition1:value condition2:value]
                while (internalSectionMatcher.find()) {
                    Section section = new Section(internalSectionMatcher);
                    if (section.name != null) { // [country_create] [country_create SomeCondition:value]
                        container = templateContainerByTemplateName.get(section.name);
                        if (container == null) {
                            container = new ArrayList<>();
                            //noinspection unchecked
                            templateContainerByTemplateName.put(section.name, (List<String>) container);
                        }
                    } else if (section.key != null && section.value != null) { // [Settings:Export] [Settings:Export SomeCondition:value]
                        /*if (section.key.equalsIgnoreCase("SomeCondition")) {
                            if (!section.value condition checks) {
                                container = null;
                                continue outer;
                            }
                        } else */if (section.key.equalsIgnoreCase("Settings")) {
                            Object configBySectionName = config.get(section.value);
                            if (configBySectionName != null) {
                                if (!(configBySectionName instanceof Map))
                                    throw new IllegalStateException("Failed parse config, due " +
                                            "config section '" + section.key + ":" + section.value + "' already exists as config key, line '" + line + "'");
                            } else {
                                configBySectionName = config.getClass().getDeclaredConstructor().newInstance();
                                config.put(section.value, configBySectionName);
                            }
                            container = configBySectionName;
                        }
                    }
                    sections.add(section);
                }
                if (sections.isEmpty())
                    continue;
                // [ipv4_values Settings:Export]
                if ((sections.stream().anyMatch(section -> section.name != null)
                        && sections.stream().anyMatch(section -> "Settings".equalsIgnoreCase(section.key)))
                        // [ipv4_values other_template_name]
                        || sections.stream().filter(section -> section.name != null).count() > 1
                        // [ipv4_values SomeKey:SomeValue SomeKey:SomeValue2]
                        || sections.stream().filter(section -> section.key != null)
                        .anyMatch(section -> sections.stream()
                                .filter(section2 -> section.key.equalsIgnoreCase(section2.key)).count() > 1)) {
                    throw new IllegalStateException("Failed parse config, due ambiguous section settings, line '" + line + "'");
                }
            }
        }

        Map<String, Template> templateByTemplateName = registry.getTemplateByTemplateName();
        for (Map.Entry<String, List<String>> entry : templateContainerByTemplateName.entrySet()) {
            templateByTemplateName.put(entry.getKey(), Template.compile(String.join("\n", entry.getValue())));
        }
    }

    private void consume(Object container, String line) {
        if (container == null)
            return;
        if (container instanceof List) {
            consume((List<String>) container, applySpecialChars(line));
        } else if (container instanceof Map) {
            consume((Map<String, String>) container, line);
        } else
            throw new UnsupportedOperationException("Unsupported container type '" + container.getClass() + "'");
    }

    private void consume(List<String> container, String line) {
        boolean slashOnEndLine = line.endsWith("\\");
        if (slashOnEndLine) {
            if (line.length() > 1)
                line = line.substring(0, line.length() - 1);
            else
                slashOnEndLine = false;
        }
        if (mergeToPrevious && !container.isEmpty()) {
            int prevPos = container.size() - 1;
            container.set(prevPos, container.get(prevPos) + line);
        } else {
            container.add(line);
        }
        mergeToPrevious = slashOnEndLine;
    }

    private void consume(Map<String, String> container, String line) {
        Matcher matcher = keyValuePattern.matcher(line);
        if (!matcher.matches())
            return;
        String key = matcher.group("key");
        String value = applySpecialChars(matcher.group("value"));
        String previousValue = container.put(key, value);
        if (previousValue != null)
            System.err.println("WARN: Overriding config key '" + key + "' value '" + previousValue + "' " +
                    "to value '" + value + "', line '" + line + "'");
    }

    private String applySpecialChars(String packedRaw) {
        StringBuilder sb = new StringBuilder(packedRaw);
        applySpecialChars(sb, 0, sb.length());
        return sb.toString();
    }

    /**
     * Escaper{\\$0}}} Separator{,\n}} : \\n -> \n, \n -> '\n', \$ -> \$, \\$ -> \\$, etc...
     */
    @SuppressWarnings("UnusedReturnValue")
    private int applySpecialChars(StringBuilder packedRaw,
                                  @SuppressWarnings("SameParameterValue") int startPos,
                                  int endPos) {
        final int targetCombinationLen = 2; /* \X == 2 chars */
        while (startPos <= endPos) {
            int slashPos = packedRaw.indexOf("\\", startPos);
            if (slashPos == -1)
                break;
            if (slashPos + 1 == endPos)
                break;
            char nextCh = packedRaw.charAt(slashPos + 1);
            boolean escaping = nextCh == '\\';
            if (escaping) {
                if (slashPos + 2 == endPos)
                    break;
                nextCh = packedRaw.charAt(slashPos + 2);
            }
            Character replaceableCh = replaceableCharByKey.get(nextCh);
            if (replaceableCh == null) {
                startPos = slashPos + targetCombinationLen + (escaping ? 1 : 0);
                continue;
            }
            String replaceable = String.valueOf(!escaping ? replaceableCh : "\\" + nextCh);
            int replaceableLen = replaceable.length();
            packedRaw.replace(slashPos, slashPos + targetCombinationLen + (escaping ? 1 : 0), replaceable);
            endPos += replaceableLen - targetCombinationLen - (escaping ? 1 : 0);
            startPos = slashPos + replaceableLen;
        }
        return endPos;
    }

    private static class Section {
        private final String name;
        private final String key;
        private final String value;

        private Section(Matcher m) {
            this.name = m.group("name");
            this.key = m.group("key");
            this.value = m.group("value");
        }
    }
}