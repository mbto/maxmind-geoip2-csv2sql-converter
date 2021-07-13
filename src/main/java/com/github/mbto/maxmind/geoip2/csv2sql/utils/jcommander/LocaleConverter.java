package com.github.mbto.maxmind.geoip2.csv2sql.utils.jcommander;

import com.beust.jcommander.IStringConverter;
import com.github.mbto.maxmind.geoip2.csv2sql.Args.Locale;

public class LocaleConverter implements IStringConverter<Locale> {
    @Override
    public Locale convert(String code) {
        return new Locale(code);
    }
}