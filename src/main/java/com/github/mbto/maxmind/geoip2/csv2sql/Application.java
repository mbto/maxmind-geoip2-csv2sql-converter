package com.github.mbto.maxmind.geoip2.csv2sql;

import com.beust.jcommander.JCommander;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.Location;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.SplitterIntoFiles;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.converters.IPBlockConverter;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.converters.LocationsConverter;
import com.github.mbto.maxmind.geoip2.csv2sql.utils.EmojiHolder;
import com.github.mbto.maxmind.geoip2.csv2sql.utils.IniFileParser;
import com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder.Template;
import lombok.Getter;
import org.apache.commons.compress.archivers.ArchiveEntry;
import org.apache.commons.compress.archivers.zip.ZipArchiveInputStream;
import org.apache.commons.compress.archivers.zip.ZipArchiveOutputStream;
import org.apache.commons.compress.utils.IOUtils;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpHeaders;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.Duration;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Consumer;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;
import java.util.stream.Stream;

import static com.github.mbto.maxmind.geoip2.csv2sql.utils.Constants.*;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.ProjectUtils.*;
import static java.net.http.HttpResponse.BodyHandlers;
import static java.net.http.HttpResponse.BodyHandlers.ofFileDownload;
import static java.nio.charset.StandardCharsets.UTF_8;
import static java.nio.file.StandardOpenOption.*;
import static java.util.Arrays.asList;
import static java.util.Arrays.stream;
import static java.util.Collections.singletonList;

public class Application {
    @Getter
    private final Registry registry = new Registry();
    private long startEpoch;

    public static void main(String[] argsRaw) throws Throwable {
        Application.run(argsRaw);
    }

    public static Application run(String[] argsRaw) throws Throwable {
        Application application = new Application();
        application.runApplication(argsRaw);
        return application;
    }

    public void runApplication(String[] argsRaw) throws Throwable {
        System.out.println(SOFTWARE_INFO);
        System.out.println("Supported locales: " + String.join(",", supportedLocales)
                + ", IP versions: " + supportedIpVersions.stream()
                    .map(ipVersion -> "v" + ipVersion)
                    .collect(Collectors.joining(",")));
        System.out.println("Country emoji: " + EmojiHolder.size() + " (Default: 250 country + 1 for unresolved)");
        System.out.println("Available processors: " + Runtime.getRuntime().availableProcessors() + "\n");

        Args args = registry.getArgs();
        JCommander jCommander = JCommander.newBuilder()
                .programName(SOFTWARE_NAME).columnSize(-1)
                .addObject(args).build();
        try {
            jCommander.parse(argsRaw);
            registry.allocateRegistrySettings();
        } catch (Exception e) {
            jCommander.usage();
            System.err.println("Failed parse arguments, " + e);
            return;
        }
        IniFileParser.parse(registry);

        long startEpoch = System.currentTimeMillis();
        try {
            resolveOutputDirPath();
            grab();
            if (extract()) {
                convert();
                generate();
            } else
                System.out.println("No unzipped elements found");
        } catch (Throwable e) {
            System.err.println("Failed in " + calcHumanDiff(startEpoch));
            e.printStackTrace();
            return;
        }
        System.out.println("Complete in " + calcHumanDiff(startEpoch));
    }

    void resolveOutputDirPath() throws Throwable {
        System.out.println("Resolving output directory path");
        Args args = registry.getArgs();
        Path outputDirPath = args.getOutputDirPath().toAbsolutePath();
        if (!Files.isDirectory(outputDirPath))
            Files.createDirectories(outputDirPath);
        if (!Files.isWritable(outputDirPath) || !Files.isReadable(outputDirPath))
            throw new IllegalStateException("Failed read/write output directory '" + outputDirPath + "'");
        args.setOutputDirPath(outputDirPath);
        System.out.println("Resolved output directory path '" + outputDirPath + "'");
    }

    void grab() throws Throwable {
        System.out.println("Grabbing archive");
        startEpoch = System.currentTimeMillis();

        Args args = registry.getArgs();
        String sourceArchiveURI = Template.compile(args.getSourceArchiveURI()).putContextAndResolve(registry);
        Path existedArchivePath;
        if(!(sourceArchiveURI.length() > 4 && sourceArchiveURI.substring(0, 4).toLowerCase().startsWith("http"))) {
            existedArchivePath = Paths.get(sourceArchiveURI);
            if(Files.notExists(existedArchivePath) || !Files.isRegularFile(existedArchivePath))
                throw new IllegalArgumentException("Invalid archive path '" + existedArchivePath + "'");
        } else {
            System.out.println("Requesting " + sourceArchiveURI);
            HttpRequest headRequest = HttpRequest.newBuilder(URI.create(sourceArchiveURI))
                    .method("HEAD", HttpRequest.BodyPublishers.noBody()).build();
            HttpClient httpClient = HttpClient.newBuilder()
                    .version(HttpClient.Version.HTTP_1_1)
                    .followRedirects(HttpClient.Redirect.ALWAYS)
                    .connectTimeout(Duration.ofSeconds(10))
                    .build();
            HttpResponse<String> headResponse = httpClient.send(headRequest, BodyHandlers.ofString());
            String tipInvalidSource = "Use a zip archive on the filesystem or from another http(s) source";
            if (headResponse.statusCode() != 200)
                throw new IllegalStateException("Response code not 200, but " + headResponse.statusCode() + ". " +
                        "Perhaps, a license key is invalid or not yet cached in maxmind. " +
                        "For new license keys wait 5 min for actual cache. " + tipInvalidSource);
            HttpHeaders headers = headResponse.headers();
            String contentType = headers.firstValue("content-type") // "application/zip"
                    .orElseThrow(() -> new IllegalStateException("Empty content-type header. " + tipInvalidSource));
            if (!contentType.equalsIgnoreCase("application/zip"))
                throw new IllegalStateException("Unsupported content-type '" + contentType + "'. " + tipInvalidSource);
            long newArchiveSize = headers.firstValueAsLong("content-length") // "1852406"
                    .orElseThrow(() -> new IllegalStateException("Empty content-length header. " + tipInvalidSource));
            String contentDisposition = headers.firstValue("content-disposition") // "attachment; filename=GeoLite2-Country-CSV_20210223.zip"
                    .orElseThrow(() -> new IllegalStateException("Empty content-disposition header. " + tipInvalidSource));
            // attachment; filename=GeoLite2-Country-CSV_20210223.zip -> GeoLite2-Country-CSV_20210223.zip
            // https://regex101.com/r/IVBipM/1
            Pattern archiveNamePatternFromContentDisposition = Pattern.compile("filename[^;=\\n]*=(?:(\\\\?['\"])(.*?)\\1|(?:[^\\s]+'.*?')?([^;\\n]*))");
            Matcher matcher = archiveNamePatternFromContentDisposition.matcher(contentDisposition);
            String archiveFilename = null;
            if(matcher.find()) {
                for (int groupId = 3; groupId >= 2; groupId--) {
                    archiveFilename = matcher.group(groupId);
                    if(archiveFilename != null && !archiveFilename.isBlank())
                        break;
                }
            }
            if(archiveFilename == null || archiveFilename.isBlank())
                throw new IllegalStateException("Unable to extract archive name from content-disposition header '"
                        + contentDisposition + "' -> '" + archiveFilename + "'. " + tipInvalidSource);

            System.out.println("Extracted from headers: archive name '" + archiveFilename + "'" + buildHumanSize(newArchiveSize));
            existedArchivePath = args.getOutputDirPath().resolve(archiveFilename);
            // C:\\maxmind-geoip2-csv2sql-converter\\GeoLite2-Country-CSV_20210223.zip
            if (Files.notExists(existedArchivePath) || newArchiveSize != Files.size(existedArchivePath)) {
                System.out.println("Downloading archive to '" + existedArchivePath + "'");
                HttpRequest getRequest = HttpRequest.newBuilder(URI.create(sourceArchiveURI)).GET().build();
                HttpResponse<Path> responseFile = httpClient.send(getRequest, ofFileDownload(existedArchivePath.getParent(), TRUNCATE_EXISTING, CREATE, WRITE));
                if (responseFile.statusCode() != 200)
                    throw new IllegalStateException("Response code from server not 200, but " + headResponse.statusCode() + ". " + tipInvalidSource);
                existedArchivePath = responseFile.body();
            } else {
                System.out.println("Archive with same size already exists");
            }
        }
        System.out.println("Resolved archive path '" + existedArchivePath + "' in " + calcHumanDiff(startEpoch)
                + buildHumanSize(Files.size(existedArchivePath)));
        registry.setArchivePath(existedArchivePath);
        registry.allocateScriptsPath();
    }

    boolean extract() throws Throwable {
        System.out.println("Extracting archive");
        startEpoch = System.currentTimeMillis();

        List<String> filenamesToExtract = Stream.concat(
                stream(extractLocationsFilenames(registry)),
                Stream.of(extractIPBlockFilenames(registry))
        ).collect(Collectors.toList());
        int unzipped = 0;
        try (var zais = new ZipArchiveInputStream(new BufferedInputStream(Files.newInputStream(registry.getArchivePath())))) {
            ArchiveEntry entry;
            while ((entry = zais.getNextEntry()) != null) {
                if (!zais.canReadEntryData(entry) || entry.isDirectory())
                    continue;
                String sourceFilename = entry.getName();
                int slash = sourceFilename.lastIndexOf("/");
                if (slash > -1)
                    sourceFilename = sourceFilename.substring(slash + 1);
                boolean founded = false;
                for (String filenameToExtract : filenamesToExtract) {
                    if (filenameToExtract.equalsIgnoreCase(sourceFilename)) {
                        sourceFilename = filenameToExtract;
                        founded = true;
                        break;
                    }
                }
                if (!founded)
                    continue;
                Path resolvedScriptPath = registry.getScriptsPath().resolve(sourceFilename);
                System.out.println("Extracting '" + sourceFilename + "' -> '" + resolvedScriptPath + "'");
                try (var bos = new BufferedOutputStream(Files.newOutputStream(resolvedScriptPath, TRUNCATE_EXISTING, CREATE, WRITE))) {
                    registry.getCsvSourcesPaths().add(resolvedScriptPath);
                    IOUtils.copy(zais, bos);
                    bos.flush();
                    ++unzipped;
                }
            }
        }
        System.out.println("Extracted " + unzipped + " entries in " + calcHumanDiff(startEpoch));
        return unzipped > 0;
    }

    void convert() throws Throwable {
        // streaming to prevent OutOfMemoryError, because GeoLite2-City-Blocks-IPv4.csv size > 200 mb
        int queueCapacity = 128;
        new LocationsConverter(registry, queueCapacity).call();
        final int ipVersionsCount = registry.getArgs().getIpVersions().size();
        ExecutorService es = Executors.newWorkStealingPool(ipVersionsCount);
        try {
            List<IPBlockConverter> callables = registry.getArgs().getIpVersions()
                    .stream()
                    .map(ipVersion -> new IPBlockConverter(registry, IP_VERSION_PREFIX + ipVersion, queueCapacity / ipVersionsCount))
                    .collect(Collectors.toList());
            for (Future<Void> f : es.invokeAll(callables)) {
                f.get();
            }
        } finally {
            es.shutdown();
        }
        if (registry.getArgs().getDeleteCSVs()) {
            deleteSources(registry.getCsvSourcesPaths());
        }
        registry.getGeneratedScriptsPaths().addAll(SplitterIntoFiles.scriptFilePaths);
    }

    void generate() throws IOException {
        System.out.println("Generating scripts");
        startEpoch = System.currentTimeMillis();

        Args args = registry.getArgs();
        Path scriptsPath = registry.getScriptsPath();
        Consumer<Template> putContextFunc = (Template template) -> {
            template.putContext("locales", args.getLocaleCodes());
            template.putContext("args", registry.getArgs());
            template.putContext("config", registry.getConfig());
            template.putContext("locationMaxLengths", registry.allocateMaxLengthsContainer(Location.class.getSimpleName().toLowerCase()));
            for (Integer ipVersion : supportedIpVersions) {
                template.putContext(IP_VERSION_PREFIX + ipVersion + "MaxLengths",
                        registry.allocateMaxLengthsContainer(IP_VERSION_PREFIX + ipVersion));
            }
        };
        List<Path> toArchiveFilePaths = new ArrayList<>(); // sorting required: create - insert - indexes
        List<Path> createScriptsFilePaths = new ArrayList<>();
        writeExportTemplates(scriptsPath, putContextFunc, singletonList("create"), asList(toArchiveFilePaths, createScriptsFilePaths));
        toArchiveFilePaths.addAll(SplitterIntoFiles.scriptFilePaths);

        List<Path> indexScriptsFilePaths = new ArrayList<>();
        writeExportTemplates(scriptsPath, putContextFunc, singletonList("indexes"), asList(toArchiveFilePaths, indexScriptsFilePaths));

        writeExportTemplates(scriptsPath,
                (Template template) -> {
                    putContextFunc.accept(template);
                    template.putContext("createPaths", createScriptsFilePaths);
                    template.putContext("insertPaths", new ArrayList<>(SplitterIntoFiles.scriptFilePaths));
                    template.putContext("indexPaths", indexScriptsFilePaths);
                }, asList("data", "loader"), singletonList(toArchiveFilePaths));

        SplitterIntoFiles.scriptFilePaths.clear();
        System.out.println("Finished generating scripts in " + calcHumanDiff(startEpoch));

        String outputArchiveName = args.getOutputArchiveName();
        if(outputArchiveName != null && !outputArchiveName.isBlank()) {
            Matcher m = Pattern.compile("[^:/\\\\]+").matcher(outputArchiveName);
            boolean founded = false;
            if(m.find()) {
                outputArchiveName = m.group(0).trim();
                founded = true;
            }
            if(!founded || outputArchiveName.isBlank()) {
                outputArchiveName = DEFAULT_ARCHIVE_NAME;
                args.setOutputArchiveName(outputArchiveName);
            }

            Path outputArchivePath = scriptsPath.resolve(outputArchiveName);
            System.out.println("Started building '" + outputArchivePath.getFileName() + "' with " + toArchiveFilePaths.size() + " entries");

            startEpoch = System.currentTimeMillis();
            try (var zaos = new ZipArchiveOutputStream(new BufferedOutputStream(Files.newOutputStream(outputArchivePath, TRUNCATE_EXISTING, CREATE, WRITE)))) {
//                zaos.setLevel(Deflater.BEST_COMPRESSION); // with BEST_COMPRESSION:22 sec, without:10 sec (+ ~1mb)
                zaos.setComment(LocalDateTime.now()
                        .format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss", Locale.ENGLISH)) + "\n"
                        + "Auto-generated by " + SOFTWARE_INFO + "\n"
                        + buildArgsSummary(registry, false) + "\n"
                        + buildStats(registry));

                for (Path toArchiveFilePath : toArchiveFilePaths) {
                    System.out.println("Archiving '" + toArchiveFilePath.getFileName() + "'" + buildHumanSize(Files.size(toArchiveFilePath)));
                    ArchiveEntry archiveEntry = zaos.createArchiveEntry(toArchiveFilePath.toFile(), toArchiveFilePath.getFileName().toString());
                    zaos.putArchiveEntry(archiveEntry);
                    try (var is = new BufferedInputStream(Files.newInputStream(toArchiveFilePath))) {
                        IOUtils.copy(is, zaos);
                    }
                    zaos.closeArchiveEntry();
                }
                zaos.finish();
            }
            System.out.println("Finished building '" + outputArchivePath.getFileName() + "' in " + calcHumanDiff(startEpoch)
                    + buildHumanSize(Files.size(outputArchivePath)));
        } else
            System.out.println("Skip archiving");

        if (registry.getArgs().getDeleteScripts()) {
            deleteSources(registry.getGeneratedScriptsPaths());
        }

        System.out.println(buildStats(registry));
    }

    private void writeExportTemplates(Path scriptsPath,
                                      Consumer<Template> putContextFunc,
                                      List<String> requestQualifiers,
                                      List<Collection<Path>> filePathsContainers) throws IOException {
        Pattern exportFilenamesPattern = Pattern.compile("^((.+?)_(.+))_filename$");
        //noinspection unchecked
        Map<String, String> exportConfig = (Map<String, String>) registry.getConfig().get("Export");
        for (Map.Entry<String, String> entry : exportConfig.entrySet()) {
            String settingsKey = entry.getKey();
            Matcher matcher = exportFilenamesPattern.matcher(settingsKey);
            if (!matcher.find())
                continue;
            String templateName = matcher.group(1); // country_indexes
//            String templateDataType = matcher.group(2); // country
            String templateQualifier = matcher.group(3); // indexes
            for (String requestQualifier : requestQualifiers) {
                if (!requestQualifier.equalsIgnoreCase(templateQualifier))
                    continue;

                Path resolvedTemplatePath = scriptsPath.resolve(exportConfig.get(settingsKey));
                System.out.println("'" + templateName + "' -> '" + resolvedTemplatePath.getFileName() + "'");

                Template template = registry.getTemplateByTemplateName().get(templateName);
                putContextFunc.accept(template);
                Files.writeString(resolvedTemplatePath, template.resolve(), UTF_8, TRUNCATE_EXISTING, CREATE, WRITE);
                for (Collection<Path> filePathsContainer : filePathsContainers) {
                    filePathsContainer.add(resolvedTemplatePath);
                }
                registry.getGeneratedScriptsPaths().add(resolvedTemplatePath);
            }
        }
    }

    private void deleteSources(List<Path> paths) {
        for (Path path : paths) {
            if (Files.notExists(path) || !Files.isRegularFile(path)) {
                System.out.println("Skip deleting '" + path + "'");
                continue;
            }
            try {
                Files.delete(path);
                System.out.println("Deleted '" + path + "'");
            } catch (Exception e) {
                System.err.println("Failed delete '" + path + "'");
                e.printStackTrace();
            }
        }
        paths.clear();
    }
}