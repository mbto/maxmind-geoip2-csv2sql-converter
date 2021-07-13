package com.github.mbto.maxmind.geoip2.csv2sql.streaming;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.LinkedHashSet;
import java.util.Set;

@Getter
public class Message<T> {
    private final T object;
    private final Event event;

    private final Set<SplitterIntoFiles> splitters = new LinkedHashSet<>(5, 1f);

    public Message(T object, Event event) {
        this.object = object;
        this.event = event;
    }

    public Message(T object, Event event, SplitterIntoFiles splitter) {
        this.object = object;
        this.event = event;
        addSplitter(splitter);
    }

    public void addSplitter(SplitterIntoFiles splitter) {
        splitters.add(splitter);
    }
}