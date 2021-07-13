package com.github.mbto.maxmind.geoip2.csv2sql.streaming.converters;

import com.github.mbto.maxmind.geoip2.csv2sql.Registry;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.Message;

import java.util.concurrent.Callable;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

import static com.github.mbto.maxmind.geoip2.csv2sql.streaming.Event.TERMINATE;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.ProjectUtils.*;

public abstract class AbstractConverter implements Callable<Void> {
    protected final Registry registry;
    protected final String dataType;
    protected final LinkedBlockingQueue<Message<?>> messageQueue;

    protected Thread writerT;

    public AbstractConverter(Registry registry, String dataType, int queueCapacity) {
        this.registry = registry;
        this.dataType = dataType;
        this.messageQueue = new LinkedBlockingQueue<>(queueCapacity);
    }

    @Override
    public Void call() throws Exception {
        long startEpoch = System.currentTimeMillis();
        threadPrintln(System.out, "Started '" + dataType + " converter'");
        try {
            return work();
        } catch (Throwable e) {
            throw new Exception("Exception in '" + dataType + " converter'", e);
        } finally {
            terminateWriter();
            threadPrintln(System.out, "Finished '" + dataType + " converter' in " + calcHumanDiff(startEpoch));
        }
    }

    protected abstract Void work() throws Throwable;

    protected void terminateWriter() {
        if (writerT != null && writerT.isAlive()) {
            threadPrintln(System.out, "Waiting for terminate writer from '" + dataType + " converter'");
            try {
                messageQueue.put(new Message<>(null, TERMINATE));
                writerT.join(/*TimeUnit.SECONDS.toMillis(3)*/);
            } catch (InterruptedException ignored) {}
            threadPrintln(System.out, "Terminated writer from '" + dataType + " converter'");
        }
    }
}