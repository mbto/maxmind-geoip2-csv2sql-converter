package com.github.mbto.maxmind.geoip2.csv2sql.streaming;

import lombok.Getter;

import java.io.BufferedReader;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Iterator;

import static java.nio.charset.StandardCharsets.UTF_8;

@Getter
public class BRWrapper implements Iterator<String> {
    private final Path csvPath;
    private final BufferedReader br;
    private Iterator<String> iterator;

    public BRWrapper(Path csvPath) throws IOException {
        this.csvPath = csvPath;
        this.br = Files.newBufferedReader(this.csvPath, UTF_8);
    }

    public void openIterator() {
        this.iterator = br.lines().iterator();
    }

    public void close() throws IOException {
        br.close();
    }

    @Override
    public boolean hasNext() {
        return iterator.hasNext();
    }

    @Override
    public String next() {
        return iterator.next();
    }
}