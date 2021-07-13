package com.github.mbto.maxmind.geoip2.csv2sql.streaming.writers;

import com.github.mbto.maxmind.geoip2.csv2sql.Registry;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.Event;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.Message;
import com.github.mbto.maxmind.geoip2.csv2sql.streaming.SplitterIntoFiles;

import java.util.concurrent.LinkedBlockingQueue;

import static com.github.mbto.maxmind.geoip2.csv2sql.streaming.Event.WRITE;
import static com.github.mbto.maxmind.geoip2.csv2sql.streaming.Event.TERMINATE;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.ProjectUtils.threadPrintln;

public class Writer extends AbstractWriterTask {
    public Writer(Registry registry, String dataType, LinkedBlockingQueue<Message<?>> messageQueue) {
        super(registry, dataType, messageQueue);
    }

    @Override
    protected Void work() throws Throwable {
        outer: while (true) {
            Message<?> message;
            try {
                message = messageQueue.take();
            } catch (Throwable e) {
                threadPrintln(System.err, "Suppressed exception while taking message in '" + dataType + " writer', " + e);
                continue;
            }
            Event event = message.getEvent();
            if (event == TERMINATE) {
                break;
            }
            Object object = message.getObject();
            if (event != WRITE) {
                for (SplitterIntoFiles splitter : splitters.values()) {
                    flushAndClose(splitter);
                }
                throw new RuntimeException("Unsupported message event '" + event + "' with "
                        + object + " in '" + dataType + " writer'");
            }
            for (SplitterIntoFiles splitter : message.getSplitters()) {
                splitter.setElement(object);
                try {
                    splitter.writeValues();
                } catch (Throwable e) {
                    stopProcessing(splitter, e);
                    break outer;
                }
                registry.incStats(splitter.getDataType());
            }
        }
        for (SplitterIntoFiles splitter : splitters.values()) {
            flushAndClose(splitter);
        }
        return null;
    }
}
/* geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,subdivision_1_iso_code,subdivision_1_name,subdivision_2_iso_code,subdivision_2_name,city_name,metro_code,time_zone,is_in_european_union
5819,en,EU,Europe,CY,Cyprus,02,"Limassol District",,,Souni,,Asia/Nicosia,1
18918,en,EU,Europe,CY,Cyprus,04,Ammochostos,,,Protaras,,Asia/Famagusta,1
49518,en,AF,Africa,RW,Rwanda,,,,,,,Africa/Kigali,0
49747,en,AF,Africa,SO,Somalia,BK,Bakool,,,Oddur,,Africa/Mogadishu,0
51537,en,AF,Africa,SO,Somalia,,,,,,,Africa/Mogadishu,0
6255113,ru,EU,"Европа",ES,"Испания",VC,"Область Валенсия",A,,,,Europe/Madrid,1
6255147,ru,AS,"Азия",,,,,,,,,Australia/Perth,0
6255148,ru,EU,"Европа",,,,,,,,,Europe/Vaduz,0
6255414,ru,AS,"Азия",ID,"Индонезия",YO,,,,,,Asia/Jakarta,0

5819,ru,EU,"Европа",CY,"Кипр",02,,,,,,Asia/Nicosia,1
18918,ru,EU,"Европа",CY,"Кипр",04,,,,"Протарас",,Asia/Famagusta,1
49518,ru,AF,"Африка",RW,"Руанда",,,,,,,Africa/Kigali,0
49747,ru,AF,"Африка",SO,Сомали,BK,,,,,,Africa/Mogadishu,0
51537,ru,AF,"Африка",SO,Сомали,,,,,,,Africa/Mogadishu,0

geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union
6252001,en,NA,"North America",US,"United States",0
6254930,en,AS,Asia,PS,Palestine,0
6255147,en,AS,Asia,,,0
6255148,en,EU,Europe,,,0
6290252,en,EU,Europe,RS,Serbia,0
6697173,en,AN,Antarctica,AQ,Antarctica,0

network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider,postal_code,latitude,longitude,accuracy_radius
1.0.0.0/24,2077456,2077456,,0,0,,-33.4940,143.2104,1000
1.0.1.0/24,1814991,1814991,,0,0,,34.7732,113.7220,1000
1.0.2.0/23,1814991,1814991,,0,0,,34.7732,113.7220,1000
1.0.4.0/22,2077456,2077456,,0,0,,-33.4940,143.2104,1000
31.25.137.0/24,449205,99237,6252001,0,0,09333,33.2800,43.5049,1000

network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider,postal_code,latitude,longitude,accuracy_radius
2a7:1c44:39f3:1b::/64,2657896,,,0,0,8004,47.3624,8.5394,100
2000:db8::/32,5332921,,,0,0,93614,37.2502,-119.7513,100
2001:200::/32,1861060,1861060,,0,0,,35.6897,139.6895,100
2001:208::/32,1880251,1880251,,0,0,,1.3673,103.8014,100 */