package com.github.mbto.maxmind.geoip2.csv2sql.utils;

import com.github.mbto.maxmind.geoip2.csv2sql.Args;
import com.github.mbto.maxmind.geoip2.csv2sql.Registry;
import com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder.Template;

import java.io.PrintStream;
import java.net.URL;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.text.DecimalFormat;
import java.text.DecimalFormatSymbols;
import java.util.Optional;
import java.util.stream.Collectors;

import static com.github.mbto.maxmind.geoip2.csv2sql.utils.Constants.IP_VERSION_PREFIX;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder.ParseUtils.StringUtils.split2;

public abstract class ProjectUtils {
    public static final DecimalFormat decLongFormat;

    static {
        DecimalFormatSymbols separators = new DecimalFormatSymbols();
        separators.setDecimalSeparator(',');
        separators.setGroupingSeparator(' ');

        decLongFormat = new DecimalFormat("###,###", separators);
        decLongFormat.setGroupingUsed(true);
        decLongFormat.setMinimumFractionDigits(0);
        decLongFormat.setMaximumFractionDigits(0);
    }

    public static Path resolveConfigDirectory() {
        String defaultURI = null;
        try {
            defaultURI = URLDecoder.decode(ProjectUtils.class.getResource("").toString(), StandardCharsets.UTF_8); // R:\\test%20test\\ -> R:\\test test\\

            if (defaultURI.startsWith("file:/")) {
// file:/C:/idea/maxmind-geoip2-csv2sql-converter/build/classes/java/main/com/github/mbto/maxmind/geoip2/csv2sql/utils/
                return Paths.get("").resolve("src").resolve("main").resolve("resources").toAbsolutePath();
            } else {
// jar:file:/C:/idea/maxmind-geoip2-csv2sql-converter/build/distributions/maxmind-geoip2-csv2sql-converter-1.0/lib/maxmind-geoip2-csv2sql-converter-1.0.jar!/com/github/mbto/maxmind/geoip2/csv2sql/utils/
                String jarPrefix = "jar:file:/";
                if (defaultURI.startsWith(jarPrefix)) {
// C:/idea/maxmind-geoip2-csv2sql-converter/build/distributions/maxmind-geoip2-csv2sql-converter-1.0/lib/maxmind-geoip2-csv2sql-converter-1.0.jar
                    String substring = defaultURI.substring(jarPrefix.length(), defaultURI.lastIndexOf('!'));
                    if(!substring.contains(":"))
                        substring = "/" + substring;
                    Path jarPath = Paths.get(substring);
                    return jarPath.getParent().getParent().resolve("bin").toAbsolutePath();
                } else
                    throw new UnsupportedOperationException("Jar prefix '" + jarPrefix + "' not founded");
            }
        } catch (Exception e) {
            throw new IllegalStateException("Failed determine resource directory from defaultURI '" + defaultURI + "'", e);
        }
    }

    public static long MBtoBytes(int mb) {
        return mb * 1024 * 1024L;
    }

    public static String calcHumanDiff(long start) {
        long diff = (System.currentTimeMillis() - start) / 1000;
        return (diff / 60) + "m " + (diff % 60) + "s";
    }

    /*public static String nullIfEmpty(String value) {
        if (value.isEmpty())
            return null;

        return value;
    }

    public static String emptyIfNull(Object value) {
        if (value == null)
            return "";

        return value.toString();
    }*/

    public static void threadPrintln(PrintStream printStream, String msg) {
        String threadName = Thread.currentThread().getName();
        int len = threadName.length();
        if (len > 9) {
            threadName = threadName.substring(len - 9);
        }
        printStream.println(String.format("[%9.9s]", threadName) + " " + msg);
    }

    public static String buildHumanSize(long value) {
        return " @ " + decLongFormat.format(value) + " bytes " + String.format("(%.2f mb)", value / 1024f / 1024f);
    }

    public static String buildArgsSummary(Registry registry, boolean archiveFullPath) {
        Args args = registry.getArgs();
        Path archivePath = registry.getArchivePath();
        return "Summary:\n"
                + "  Edition ID: " + registry.getEditionId() + "\n"
                + "  DBMS name: " + registry.getDBMSname() + "\n"
                + "  Profile name: " + registry.getConfigProfileName() + "\n"
                + "Arguments of converting:\n"
                + "  IP version" + (args.getIpVersions().size() > 1 ? "s" : "") + ": "
                    + args.getIpVersions().stream()
                    .map(ipVersion -> "v" + ipVersion)
                    .collect(Collectors.joining(",")) + "\n"
                + "  " + "Locales: " + args.getLocaleCodes().stream().map(Args.Locale::toString).collect(Collectors.joining(",")) + "\n"
                + "  " + "Locations filter:" + (registry.getAllowedLocationValuesByGroupName() == null
                    ? " no filter" : ("\n    " + registry.getAllowedLocationValuesByGroupName()
                        .entrySet()
                        .stream()
                        .map(entry -> entry.getKey() + "=" + entry.getValue()
                                .stream()
                                .map(param -> "\"" + param + "\"")
                                .collect(Collectors.joining(","))
                        ).collect(Collectors.joining("\n    "))
                    )) + "\n"
                + "  " + "Max megabytes count per file: " + args.getMegaBytesCountPerFile() + "\n"
                + "  " + "Max records per line: " + args.getRecordsPerLine() + "\n"
                + "  " + "Values count per insert: "
                    + Optional.ofNullable(registry.getFromExportSection("values_count_per_insert", false))
                        .filter(s -> !s.isBlank())
                        .orElse("no limit")
                    + "\n"
                + "Sources from '" + (archiveFullPath ? archivePath : archivePath != null ? archivePath.getFileName() : "") + "'\n"
                + "  " + String.join("\n  ", extractLocationsFilenames(registry, "'")) + "\n"
                + "  " + String.join("\n  ", extractIPBlockFilenames(registry, "'"));
    }

    public static String buildStats(Registry registry) {
        return "Stats:" + (registry.getStats().isEmpty()
                ? " no stats" : ("\n  " + registry.getStats()
                .entrySet()
                .stream()
                .map(entry -> entry.getKey() + ": " + entry.getValue())
                .collect(Collectors.joining("\n  ")))
        );
    }

    public static String[] extractLocationsFilenames(Registry registry) {
        return extractLocationsFilenames(registry, "");
    }

    public static String[] extractLocationsFilenames(Registry registry, String wrapAround) {
        String filenameTemplate = registry.getFromImportSection("locations_filenames", true);
        Template template = Template.compile(filenameTemplate);
        String resolved = template.putContextAndResolve("locales", registry.getArgs().getLocaleCodes());
        return split2(resolved, ',', wrapAround, true, true);
    }

    public static String extractIPBlockFilename(Registry registry, String dataType) {
        return registry.getFromImportSection(dataType + "_filename", true);
    }

    public static String[] extractIPBlockFilenames(Registry registry) {
        return extractIPBlockFilenames(registry, "");
    }

    public static String[] extractIPBlockFilenames(Registry registry, String wrapAround) {
        return registry.getArgs().getIpVersions()
                .stream()
                .map(ipVersion -> wrapAround + extractIPBlockFilename(registry, IP_VERSION_PREFIX + ipVersion) + wrapAround)
                .toArray(String[]::new);
    }
}