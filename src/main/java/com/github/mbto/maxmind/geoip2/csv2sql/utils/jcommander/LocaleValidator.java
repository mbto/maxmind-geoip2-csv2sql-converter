package com.github.mbto.maxmind.geoip2.csv2sql.utils.jcommander;

import com.beust.jcommander.IValueValidator;
import com.beust.jcommander.ParameterException;
import com.github.mbto.maxmind.geoip2.csv2sql.Args;

import java.util.List;

import static com.github.mbto.maxmind.geoip2.csv2sql.Args.*;
import static com.github.mbto.maxmind.geoip2.csv2sql.utils.Constants.supportedLocales;

public class LocaleValidator implements IValueValidator<List<Locale>> {
    @Override
    public void validate(String name, List<Locale> locales) throws ParameterException {
        for (Locale locale : locales) {
            if(!supportedLocales.contains(locale.getCode())) {
                throw new ParameterException("Locale '" + locale.getCode() + "' not supported, " +
                        "only " + supportedLocales);
            }
        }
    }
}