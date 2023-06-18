package com.github.mbto.maxmind.geoip2.csv2sql.streaming.converters;

import com.github.mbto.maxmind.geoip2.csv2sql.Registry;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.Message;

import java.util.concurrent.Callable;
import java.util.concurrent.LinkedBlockingQueue;

import static com.github.mbto.maxmind.geoip2.csv2sql.streaming.Event.TERMINATE;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.ProjectUtils.calcHumanDiff;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.ProjectUtils.threadPrintln;

public abstract class AbstractConverter implements Callable<Void> {
    protected final Registry registry;
    protected final String dataType;
    protected final LinkedBlockingQueue<Message<?>> messageQueue;
    protected final boolean logIgnored;

    protected Thread writerT;

    public AbstractConverter(Registry registry, String dataType, int queueCapacity, boolean logIgnored) {
        this.registry = registry;
        this.dataType = dataType;
        this.messageQueue = new LinkedBlockingQueue<>(queueCapacity);
        this.logIgnored = logIgnored;
    }

    @Override
    public Void call() throws Exception {
        long startEpoch = System.currentTimeMillis();
        threadPrintln(System.out, "Started " + getConverterName());
        try {
            return work();
        } catch (Throwable e) {
            throw new Exception("Exception in " + getConverterName(), e);
        } finally {
            terminateWriter();
            threadPrintln(System.out, "Finished " + getConverterName() + " in " + calcHumanDiff(startEpoch));
        }
    }

    protected abstract Void work() throws Throwable;

    protected void terminateWriter() {
        if (writerT != null && writerT.isAlive()) {
            threadPrintln(System.out, "Waiting for terminate writer from " + getConverterName());
            try {
                messageQueue.put(new Message<>(null, TERMINATE));
                writerT.join(/*java.util.concurrent.TimeUnit.SECONDS.toMillis(3)*/);
            } catch (InterruptedException ignored) {}
            threadPrintln(System.out, "Terminated writer from " + getConverterName());
        }
    }

    protected String getConverterName() {
        return "'" + dataType + " converter'";
    }
}