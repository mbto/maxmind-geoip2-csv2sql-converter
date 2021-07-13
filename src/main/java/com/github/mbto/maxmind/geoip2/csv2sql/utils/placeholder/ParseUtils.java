package com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder;

import java.util.ArrayList;
import java.util.List;

public abstract class ParseUtils {
    public static String[] splitWithoutBrackets(String value, char delimeter, boolean trim, boolean ignoreEmpty) {
        return splitWithoutBrackets(value, delimeter, "", trim, ignoreEmpty);
    }
    public static String[] splitWithoutBrackets(String value, char delimeter, String wrapAround, boolean trim, boolean ignoreEmpty) {
        int countOpenedRoundBrackets = 0; // ( )
        int lastDelimeterPos = 0, pos = 0;
        List<String> parts = new ArrayList<>();
        for (int len = value.length(); pos < len; pos++) {
            char ch = value.charAt(pos);
            if (ch == delimeter) {
                if (countOpenedRoundBrackets > 0)
                    continue;
                addWithConditions(parts, value.substring(lastDelimeterPos, pos), wrapAround, trim, ignoreEmpty);
                lastDelimeterPos = pos + 1;
            } else if (ch == '(') {
                ++countOpenedRoundBrackets;
            } else if (ch == ')') {
                if (--countOpenedRoundBrackets < 0)
                    throw new IllegalStateException("Invalid syntax '" + value + "'");
            }
        }
        addWithConditions(parts, value.substring(lastDelimeterPos, pos), wrapAround, trim, ignoreEmpty);
        return parts.toArray(new String[0]);
    }

    /*public static String arrayToStringCounted(String[] array) {
        StringBuilder sb = new StringBuilder();
        sb.append('[');
        for (int i = 0, arrayLength = array.length; i < arrayLength; i++) {
            sb.append(i).append(':').append(array[i]);
            if(i + 1 < arrayLength)
                sb.append('\n');
        }
        return sb.append(']').toString();
    }*/

    /**
     * Modified splitWorker method from org.apache.commons:commons-lang3:3.9
     */
    public static class StringUtils {
        public static final String[] EMPTY_STRING_ARRAY = new String[0];

        public static String[] split2(String str, char separatorChar, boolean trim, boolean ignoreEmpty) {
            return split2(str, separatorChar, "", trim, ignoreEmpty);
        }
        public static String[] split2(String str, char separatorChar, String wrapAround, boolean trim, boolean ignoreEmpty) {
            return splitWorker(str, separatorChar, wrapAround, true, trim, ignoreEmpty);
        }
        /**
         * Performs the logic for the {@code split} and
         * {@code splitPreserveAllTokens} methods that do not return a
         * maximum array length.
         *
         * @param str  the String to parse, may be {@code null}
         * @param separatorChar the separate character
         * @param preserveAllTokens if {@code true}, adjacent separators are
         * treated as empty token separators; if {@code false}, adjacent
         * separators are treated as one separator.
         * @return an array of parsed Strings, {@code null} if null String input
         */
        private static String[] splitWorker(String str, char separatorChar, String wrapAround,
                                            @SuppressWarnings("SameParameterValue") boolean preserveAllTokens,
                                            boolean trim, boolean ignoreEmpty) {
            if (str == null) {
                return null;
            }
            final int len = str.length();
            if (len == 0) {
                return EMPTY_STRING_ARRAY;
            }
            final List<String> list = new ArrayList<>();
            int i = 0, start = 0;
            boolean match = false;
            boolean lastMatch = false;
            while (i < len) {
                if (str.charAt(i) == separatorChar) {
                    if (match || preserveAllTokens) {
                        addWithConditions(list, str.substring(start, i), wrapAround, trim, ignoreEmpty);
                        match = false;
                        lastMatch = true;
                    }
                    start = ++i;
                    continue;
                }
                lastMatch = false;
                match = true;
                i++;
            }
            //noinspection ConstantConditions
            if (match || preserveAllTokens && lastMatch) {
                addWithConditions(list, str.substring(start, i), wrapAround, trim, ignoreEmpty);
            }
            //noinspection ToArrayCallWithZeroLengthArrayArgument
            return list.toArray(new String[list.size()]);
        }
    }
    static void addWithConditions(List<String> list, String value, String wrapAround, boolean trim, boolean ignoreEmpty) {
        if(trim)
            value = value.trim();
        if(!ignoreEmpty || !value.isEmpty())
            list.add(wrapAround + value + wrapAround);
    }
}