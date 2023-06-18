package com.github.mbto.maxmind.geoip2.csv2sql;

import org.junit.Assert;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Arrays;
import java.util.Iterator;
import java.util.Map;
import java.util.stream.Collectors;
import java.util.stream.Stream;

import static com.github.mbto.maxmind.geoip2.csv2sql.utils.Constants.SOFTWARE_NAME;

public interface Constants {
    String archiveDate = "20230616";
    String archiveExtension = ".zip";
    String resultArchiveName = "maxmind-geoip2-csv2sql-integration-test-result.zip";
    Path integrationTestsDirPath = buildintegrationTestsDirPath();
    Path resourceTestsDirPath = Paths.get("build", "resources", "test").toAbsolutePath();

    static Path buildintegrationTestsDirPath() {
        Path expectedPath = Paths.get("C:\\")
                .resolve("test test")
                .resolve("IntegrationTests")
                .resolve(SOFTWARE_NAME);
        Path root = expectedPath;
        while (true) {
            Path parent = root.getParent();
            if(parent == null) {
                return Files.isDirectory(root) ? expectedPath // C:\ exists ?
                        : Paths.get(System.getProperty("java.io.tmpdir")).resolve(SOFTWARE_NAME);
            }
            root = parent;
        }
    }

    static String buildArchiveName(String editionId) {
        return editionId + "_" + archiveDate + archiveExtension;
    }

    static String buildMySQLConfigName(String editionId) {
        return buildConfigName(editionId, "mysql");
    }

    static String buildPostgreSQLConfigName(String editionId) {
        return buildConfigName(editionId, "postgresql");
    }

    static String buildMicrosoftSql2019ConfigName(String editionId) {
        return buildConfigName(editionId, "mssql 2019");
    }

    static String buildConfigName(String editionId, String DBMSname) {
        return editionId + "." + DBMSname + ".default.ini";
    }

    static String buildIntegrationOutputDirPath(String testId) {
        return testId.isEmpty() ? integrationTestsDirPath.toString() : integrationTestsDirPath.resolve(testId).toString();
    }

    static Path buildFullArchivePath(String testId) {
        return integrationTestsDirPath
                .resolve(testId)
                .resolve(resultArchiveName);
    }

    static Stream<String> buildDefaultArgs(String editionId, String testId) {
        return Arrays.stream(new String[]{
                "-s", resourceTestsDirPath.resolve(buildArchiveName(editionId)).toString(),
                "-od", buildIntegrationOutputDirPath(testId),
                "-oa", resultArchiveName,
                "-c", buildMySQLConfigName(editionId),
                "-dc", "true",
                "-ds", "true",
        });
    }

    static void assertStats(String[] argsRaw, String editionId, String testId,
                            Map<String, Integer> expectedStats,
                            int expectedArchiveFileSize) throws Exception {
        assertStats(argsRaw, editionId, testId, expectedStats, expectedArchiveFileSize,true);
    }

    static void assertStats(String[] argsRaw, String editionId, String testId,
                            Map<String, Integer> expectedStats,
                            int expectedArchiveFileSize,
                            boolean delete) throws Exception {
        Application application = null;
        Throwable t = null;
        try {
            argsRaw = Stream.concat(Arrays.stream(argsRaw), buildDefaultArgs(editionId, testId)).toArray(String[]::new);
            application = Application.run(argsRaw);
        } catch (Throwable e) {
            t = e;
        }

        Path fullArchivePath = buildFullArchivePath(testId);
        Assert.assertTrue("Path '" + fullArchivePath + "' not a file", Files.exists(fullArchivePath) && Files.isRegularFile(fullArchivePath));

        long actualArchiveFileSize = Files.size(fullArchivePath);

        if(application != null) {
            System.out.println(application.getRegistry().getStats()
                    .entrySet()
                    .stream()
                    .map(entry -> "\t\t\tentry(\"" + entry.getKey() + "\", " + entry.getValue() + ")")
                    .collect(Collectors.joining(",\n",
                            "\t\tMap.ofEntries(\n",
                            "),\n\t\t\t\t\t\t" + actualArchiveFileSize + "},")));
        }
        if (delete) {
            // Deleting testId direcroty from: C:\test test\IntegrationTests\SOFTWARE_NAME\testId\resultArchiveName
            deleteRecursive(fullArchivePath.getParent());
        }
        Assert.assertNull(t);
        Assert.assertNotNull(application);
        Assert.assertEquals(expectedStats, application.getRegistry().getStats());
        Assert.assertEquals(expectedArchiveFileSize, actualArchiveFileSize);
    }

    static void deleteRecursive(Path path) {
        if (Files.notExists(path))
            return;
        try {
            if (Files.isDirectory(path)) {
                try (Stream<Path> list = Files.list(path)) {
                    Iterator<Path> iterator = list.iterator();
                    while (iterator.hasNext()) {
                        deleteRecursive(iterator.next());
                    }
                }
            }
            if (path.toAbsolutePath().toString().chars().filter(ch -> ch == '/' || ch == '\\').count() >= 2) {
                Files.delete(path);
                System.out.println("Deleted '" + path + "'");
            } else {
                System.out.println("Ignore deleting '" + path + "' - try to safe the root");
            }
        } catch (Exception e) {
            System.err.println("Failed deleting '" + path + "', " + e);
        }
    }
}