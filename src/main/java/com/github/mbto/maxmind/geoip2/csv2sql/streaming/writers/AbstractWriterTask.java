package com.github.mbto.maxmind.geoip2.csv2sql.streaming.writers;

import com.github.mbto.maxmind.geoip2.csv2sql.Registry;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.Message;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.SplitterIntoFiles;

import java.nio.file.Path;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.LinkedBlockingQueue;

import static com.github.mbto.maxmind.geoip2.csv2sql.utils.ProjectUtils.calcHumanDiff;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.ProjectUtils.threadPrintln;

public abstract class AbstractWriterTask implements Callable<Void> {
    public static volatile boolean exceptionOccurred;

    protected final Registry registry;
    protected final String dataType;

    protected final LinkedBlockingQueue<Message<?>> messageQueue;
    protected final Map<String, SplitterIntoFiles> splitters = new ConcurrentHashMap<>();

    protected AbstractWriterTask(Registry registry, String dataType, LinkedBlockingQueue<Message<?>> messageQueue) {
        this.registry = registry;
        this.dataType = dataType;
        this.messageQueue = messageQueue;
    }

    @Override
    public Void call() throws Exception {
        long startEpoch = System.currentTimeMillis();
        threadPrintln(System.out, "Started '" + dataType + " writer'");
        try {
            return work();
        } catch (Throwable e) {
            exceptionOccurred = true;
            throw new Exception("Exception in '" + dataType + " writer'", e);
        } finally {
            threadPrintln(System.out, "Finished '" + dataType + " writer' in " + calcHumanDiff(startEpoch));
        }
    }

    protected abstract Void work() throws Throwable;

    public SplitterIntoFiles allocateSplitter() {
        return allocateSplitter(dataType);
    }
    public SplitterIntoFiles allocateSplitter(String customDataType) {
        SplitterIntoFiles splitter = splitters.get(customDataType);
        if (splitter == null) {
            splitter = new SplitterIntoFiles(registry, customDataType);
            SplitterIntoFiles existedSplitter = splitters.putIfAbsent(customDataType, splitter);
            if (existedSplitter != null)
                splitter = existedSplitter;
        }
        return splitter;
    }

    protected void flushAndClose(SplitterIntoFiles sif) {
        if (sif != null && sif.isOpened()) {
            try {
                sif.flushAndClose();
            } catch (Throwable e) {
                sif.closeCosQuietly();
                stopProcessing(sif, e);
            }
        }
    }

    public void throwIfWriterUnavailable() {
        if (exceptionOccurred)
            throw new RuntimeException("Stop processing, due exception occurred in '" + dataType + " writer'");
    }

    protected void stopProcessing(SplitterIntoFiles sif, Throwable e) {
        messageQueue.clear();
        exceptionOccurred = true;

        Path scriptFilePath = sif.getScriptFilePath();
        threadPrintln(System.err, "Exception in '" + dataType + " writer' while building "
                + (scriptFilePath != null ? "'" + scriptFilePath.getFileName() + "'" : ""));

        e.printStackTrace();
    }
}