package com.github.mbto.maxmind.geoip2.csv2sql.streaming;

import com.github.mbto.maxmind.geoip2.csv2sql.Registry;
import com.github.mbto.maxmind.geoip2.csv2sql.Args;
import com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder.Template;
import lombok.Getter;
import lombok.Setter;
import org.apache.commons.compress.utils.CountingOutputStream;

import java.io.BufferedOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import java.util.concurrent.ConcurrentSkipListSet;

import static com.github.mbto.maxmind.geoip2.csv2sql.utils.ProjectUtils.*;
import static java.nio.charset.StandardCharsets.UTF_8;
import static java.nio.file.StandardOpenOption.*;

/**
 * Dynamically creates geo_(timezone|country|subdivision1|subdivision2|city|ipv4|ipv6)_nnnnn.sql files, splits them into n parts
 * Example: file splitting is required to keep the file size smaller than the max_allowed_packet mysql config option
 */
public class SplitterIntoFiles {
    public static final Set<Path> scriptFilePaths = new ConcurrentSkipListSet<>(Comparator.comparing(Path::getFileName));

    private final long bytesCountPerFile;
    private final int recordsPerLine;
    private final Path scriptsPath;
    @Getter
    private final String dataType;
    private final String valuesSeparator;
    private final String valuesEnd;
    private final String valuesEOF;
    private final Integer valuesCountPerInsert;
    private final String filePattern;
    private final Template templateInsert;
    private final Template templateValues;

    @Getter // AS -> N, EU -> N, NA -> N, RU -> N
    private final Map<String, Integer> idBySyntheticKey = new HashMap<>();
    private int nextId = 1;

    private CountingOutputStream cos;
    @Getter
    private Path scriptFilePath;
    @Getter
    private long valuesCounter;
    @Getter
    private int fileCounter;
    @Setter
    private Object element;
    @Getter
    private boolean isOpened;

    public SplitterIntoFiles(Registry registry, String dataType) {
        Args args = registry.getArgs();
        this.bytesCountPerFile = args.getBytesCountPerFile();
        this.recordsPerLine = args.getRecordsPerLine();
        this.scriptsPath = registry.getScriptsPath();
        this.dataType = dataType;

        this.valuesSeparator = registry.getFromExportSection("values_separator", true);
        this.valuesEnd = registry.getFromExportSection("values_end", true);
        this.valuesEOF = Optional.ofNullable(registry.getFromExportSection("values_end_of_file", false))
                .filter(s -> !s.isEmpty())
                .orElse(null);
        this.valuesCountPerInsert = Optional.ofNullable(registry.getFromExportSection("values_count_per_insert", false))
                .filter(s -> !s.isBlank())
                .map(Integer::parseInt)
                .filter(value -> value > 0)
                .orElse(null);
        this.filePattern = registry.getFromExportSection(dataType + "_insert_filename", true);

        Map<String, Template> templateByTemplateName = registry.getTemplateByTemplateName();
        templateInsert = templateByTemplateName.get(dataType + "_insert");
        templateInsert.putContext("locales", args.getLocaleCodes());

        templateValues = templateByTemplateName.get(dataType + "_values");
        templateValues.putContext("locales", args.getLocaleCodes());
    }

    private void open() throws IOException {
        scriptFilePath = scriptsPath.resolve(String.format(filePattern, fileCounter++));
        cos = new CountingOutputStream(new BufferedOutputStream(Files.newOutputStream(scriptFilePath, TRUNCATE_EXISTING, CREATE, WRITE)));
        isOpened = true;
        scriptFilePaths.add(scriptFilePath);

        threadPrintln(System.out, "Started building '" + scriptFilePath.getFileName() + "'");
        valuesCounter = 0;
        write(templateInsert.resolve());
    }

    public void writeValues() throws IOException {
        if (isOpened) {
            boolean splitInsert = valuesCountPerInsert != null && valuesCounter % valuesCountPerInsert == 0;
            if(splitInsert)
                write(valuesEnd);
            else
                write(valuesSeparator);

            if(valuesCounter > 0 && valuesCounter % recordsPerLine == 0)
                write('\n');

            if(splitInsert)
                write(templateInsert.resolve());
        } else {
            open();
        }
        write(templateValues.putContextAndResolve(element));
        if(++valuesCounter % 10000 == 0) {
            cos.flush();
        }
        if (cos.getBytesWritten() + (1024 * 100/*100 KB*/) >= bytesCountPerFile) {
            flushAndClose();
        }
    }

    public void flushAndClose() throws IOException {
        write(valuesEnd);
        if(valuesEOF != null)
            write(valuesEOF);

        cos.flush();
        cos.close();
        isOpened = false;

        long bytesWritten = cos.getBytesWritten();
        long realFilesize = Files.size(scriptFilePath);

        if (bytesWritten != realFilesize)
            throw new IllegalStateException("Failed check bytes count. Expected " + bytesWritten + ", actual " + realFilesize);

        threadPrintln(System.out, "Finished building '" + scriptFilePath.getFileName() + "'" + buildHumanSize(bytesWritten));
    }

    private void write(char value) throws IOException {
        write(String.valueOf(value));
    }

    private void write(String value) throws IOException {
        cos.write(value.getBytes(UTF_8));
    }

    public void closeCosQuietly() {
        try {
            cos.close();
        } catch (Throwable ignored) {}
    }

    public int saveSyntheticKey(String syntheticKey) {
        int id = nextId++;
        idBySyntheticKey.put(syntheticKey, id);
        return id;
    }

    public Integer getIdBySyntheticKey(String syntheticKey) {
        return idBySyntheticKey.get(syntheticKey);
    }
}