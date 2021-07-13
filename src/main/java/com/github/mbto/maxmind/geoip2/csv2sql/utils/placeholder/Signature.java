package com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder;

import lombok.Getter;
import lombok.Setter;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;

@Getter
class Signature {
    private static final Object[] emptyArray = new Object[0];

    /**
     * method or field name
     */
    private final String reference;
    private final Object[] args;
    @Setter
    private Method method;

    public Signature(String reference) {
        this.reference = reference;
        this.args = emptyArray;
    }

    public Signature(String reference, Object[] args) {
        this.reference = reference;
        this.args = args;
    }

    public Object invokeMethod(Object context) throws InvocationTargetException, IllegalAccessException {
        if (method == null)
            throw new IllegalStateException("Unable to invoke null method with context "
                    + (context != null ? context.getClass().getSimpleName() + ":" : "") + "'" + context + "'");
        return method.invoke(context, args);
    }
}