package com.github.mbto.maxmind.geoip2.csv2sql.utils.jcommander;

import com.beust.jcommander.IValueValidator;
import com.beust.jcommander.ParameterException;

import java.util.List;

import static com.github.mbto.maxmind.geoip2.csv2sql.utils.Constants.supportedIpVersions;

public class IPVersionValidator implements IValueValidator<List<Integer>> {
    @Override
    public void validate(String name, List<Integer> ipVersions) throws ParameterException {
        for (Integer ipVersion : ipVersions) {
            if (!supportedIpVersions.contains(ipVersion)) {
                throw new ParameterException("IP version '" + ipVersion + "' not supported, " +
                        "only " + supportedIpVersions);
            }
        }
    }
}