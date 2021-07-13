package com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder;

import lombok.AllArgsConstructor;
import lombok.ToString;

import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;
import java.util.stream.Stream;

import static com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder.ParseUtils.splitWithoutBrackets;

public class Template {
    private final String raw;
    private boolean internal;
    private final List<Part> parts = new ArrayList<>();
    private final Map<String, Object> contextByAlias = new HashMap<>();
    public Template(String raw) {
        this.raw = raw;
    }
    private Template(String raw, boolean internal) {
        this.raw = raw;
        this.internal = internal;
    }
    public void putContext(Map<String, Object> contextByAlias) {
        this.contextByAlias.putAll(contextByAlias);
    }
    public void putContext(String alias, Object context) {
        contextByAlias.put(alias, context);
    }
    public void putContext(Object context) {
        putContext("", context);
    }
    public String putContextAndResolve(Map<String, Object> contextByAlias) {
        putContext(contextByAlias);
        return resolve();
    }
    public String putContextAndResolve(String alias, Object context) {
        putContext(alias, context);
        return resolve();
    }
    public String putContextAndResolve(Object context) {
        putContext(context);
        return resolve();
    }
    public String resolve() {
        StringBuilder sb = new StringBuilder();
        for (Part part : parts) {
            sb.append(part.toObject());
        }
        return sb.toString();
    }
    public static Template compile(String raw) {
        return new Template(raw).compile();
    }
    public Template compile() {
        StringBuilder target = new StringBuilder(raw);
        int targetLen = target.length();
        int lastBracket = 0;
        for (int targetPos = 0; targetPos < targetLen; ) {
            char ch = target.charAt(targetPos);
            if (ch != '{') {
                ++targetPos;
                continue;
            }
            boolean hasSymbol = false;
            if(targetPos - 1 > -1) {
                char prevCh = target.charAt(targetPos - 1);
                if (prevCh == '\\') {
                    target.replace(targetPos - 1, targetPos, "");
                    --targetLen;
                    continue;
                } else if (prevCh == '#' || prevCh == '$') {
                    hasSymbol = true;
                    --targetPos;
                }
            }
            if(targetPos > lastBracket)
                parts.add(allocate(lastBracket, targetPos, target));
            lastBracket = findEndBracket(target, targetPos + (hasSymbol ? 2 : 1));
            if (lastBracket == -1) {
                System.err.println("Unable to find last bracket '}' from template (try to escape first bracket \\{), using default '" + raw + "'");
                parts.clear();
                parts.add(new Part(raw));
                return this;
            }
            parts.add(allocate(targetPos, lastBracket, target));
            targetPos = lastBracket;
        }
        if(lastBracket < targetLen)
            parts.add(allocate(lastBracket, targetLen, target));
        return this;
    }
    private Part allocate(String target) {
        return allocate(0, target.length(), new StringBuilder(target));
    }
    private Part allocate(int pos1, int pos2, StringBuilder target) {
        char fch = target.charAt(pos1);
        Character nch = pos1 + 1 < target.length() ? target.charAt(pos1 + 1) : null;
        String partRaw = target.substring(pos1, pos2);
        if(nch != null && nch == '{') {
            if (fch == '#') {
                return new Mutable(partRaw);
            } else if (fch == '$') {
                return new Resolvable(partRaw);
            }
        }
        return new Part(partRaw);
    }
    /**
     * https://regex101.com/r/6mPyN0/1
     */
    private static final Pattern resolvablePattern = Pattern.compile("([\\w\\d_]+) *\\{(.*?)}(?= |$)|(?:\\.{0,2}[\\w\\d_]+(?:\\(.*?\\))?)+(?=\\.| +[\\w\\d_]+ *\\{| *$)");
    @ToString(callSuper = true)
    private class Resolvable extends Part {
        private String prefix = "";
        private String postfix = "";
        private Pattern escape;
        private String escaper = "";
        private String defaultValue = "null";
        private String alias;
        private ReferenceNode headRefNode;
        protected Resolvable(String raw) {
            super(raw);
            Matcher matcher = resolvablePattern.matcher(unpack());
            String extractedReferences = null;
            while (matcher.find()) {
                String key = matcher.group(1);
                String value = matcher.group(2);
                if(key != null && value != null) {
                    if (key.equalsIgnoreCase("Prefix")) prefix = value;
                    else if (key.equalsIgnoreCase("Postfix")) postfix = value;
                    else if (key.equalsIgnoreCase("Escape")) escape = Pattern.compile(value);
                    else if (key.equalsIgnoreCase("Escaper")) escaper = value;
                    else if (key.equalsIgnoreCase("Default")) defaultValue = value;
                } else {
                    extractedReferences = matcher.group(0);
                }
            }
            if(extractedReferences == null || extractedReferences.isEmpty()) {
                System.err.println("Unable to extract references from placeholder '" + raw + "' from '" + Template.this.raw + "', " +
                        "due references " + (extractedReferences == null ? "not extracted" : "is empty") + ", using default");
                return;
            }
            String[] references = splitWithoutBrackets(extractedReferences, '.', false, false);
            alias = references[0];
            ReferenceNode lastRefNode = null;
            for (int i = 1; i < references.length; i++) {
                ReferenceNode refNode = new ReferenceNode(references[i]);
                if(headRefNode == null) {
                    lastRefNode = headRefNode = refNode;
                } else {
                    //noinspection ConstantConditions
                    lastRefNode = lastRefNode.setNext(refNode);
                }
            }
        }
        @Override
        public Object toObject() {
            if(alias == null)
                return raw;
            Object context = contextByAlias.get(alias);
            if(context == null) {
                System.err.println("Unable to resolve references " + headRefNode
                        + " by alias '" + alias + "', due context not present. Using default placeholder '" + raw + "'");
                return raw;
            }
            Object obj;
            try {
                obj = ReflectionUtils.resolveObjectReferenceNode(context, headRefNode);
            } catch (Exception e) {
                System.err.println("Unable to resolve references " + headRefNode
                        + " from context " + context.getClass().getSimpleName()
                        + ":'" + context + "', using default placeholder '" + raw + "'. " + e);
                return raw;
            }
            if(obj instanceof Collection) {
                Collection<?> collection = (Collection<?>) obj;
                if(collection.isEmpty()) {
                    if(internal)
                        return Collections.emptyList();
                    throw new RuntimeException("Unable to resolve placeholder '" + raw + "', references " + headRefNode
                            + " from context " + context.getClass().getSimpleName()
                            + ":'" + context + "'. Context collection is empty");
                }
                Object firstValue = collection.iterator().next();
                if(internal) {
                    Stream<?> stream = collection.stream();
                    if (firstValue instanceof Collection) // recursive not needed yet
                        stream = stream.flatMap(internalCollection -> ((Collection<?>) internalCollection).stream());
                    return stream.map(this::buildResolved)
                            .collect(Collectors.toList());
                } else {
                    return buildResolved(firstValue);
                }
            }
            return buildResolved(obj);
        }
        private String buildResolved(Object obj) {
            if (obj == null)
                return defaultValue;
            if (escape == null)
                return prefix + obj + postfix;
            return prefix + escape.matcher(obj.toString()).replaceAll(escaper) + postfix;
        }
    }
    @ToString(callSuper = true)
    private class Mutable extends Part {
        private Template template;
        private String separator = "";
        private String defaultValue = "null";
        private boolean disableIfEmptyCollection;
        protected Mutable(String raw) {
            super(raw);
            StringBuilder packedRaw = new StringBuilder(unpack());
            int lastBrPos = 0;
            while (true) {
                int brPos1 = packedRaw.indexOf("{", lastBrPos);
                if (brPos1 == -1)
                    break;
                int endBracket = findEndBracket(packedRaw, brPos1 + 1);
                if (endBracket == -1)
                    throw new IllegalArgumentException("Unable to find end bracket '}' from placeholder " +
                            "'" + packedRaw + "'");
// forEach
// Separator
                String key = packedRaw.substring(lastBrPos, brPos1).trim();
// {some text start ${.localeValues.values()..get("country_name") Prefix{'} Postfix{'} Escape{[']} Escaper{\\$0}} some text end}
// {,}
                String value = packedRaw.substring(brPos1 + 1, endBracket - 1);
                if(key.equalsIgnoreCase("forEach")) {
                    template = new Template(value, true);
                } else if(key.equalsIgnoreCase("Separator")) {
                    separator = value;
                } else if(key.equalsIgnoreCase("Default")) {
                    defaultValue = value;
                } else if(key.equalsIgnoreCase("Disable")) {
                    if(value.equalsIgnoreCase("EmptyCollection"))
                        disableIfEmptyCollection = true;
                }
                lastBrPos = endBracket;
            }
            if(template == null)
                System.err.println("Unable to define internal template from placeholder '" + raw + "', using default");
            else
                template.compile();
        }
// some text start ${.localeValues.values()..get("country_name") Prefix{'} Postfix{'} Escape{[']} Escaper{\\$0}} some text end
        @Override
        public Object toObject() {
            if(template == null)
                return raw;
            List<Part> internalParts = template.parts;
            if(internalParts.isEmpty())
                return "";
            template.putContext(contextByAlias);
            int mutationSize = 1;
            List<InternalResolved> resolvedList = new ArrayList<>();
            for (Part internalPart : internalParts) {
                Object obj = internalPart.toObject();
                if(obj instanceof Collection) {
                    int collectionSize = ((Collection<?>) obj).size();
                    if(disableIfEmptyCollection && collectionSize == 0)
                        return "";
                    if(collectionSize > mutationSize)
                        mutationSize = collectionSize;
                }
                resolvedList.add(new InternalResolved(obj == null ? defaultValue : obj, internalPart));
            }
/* Mutate: {some text start }[AAA,BBB,CCC,DDD,EEE]{ }[111,222,333]{ some text end}
0               1   2   3            internalParts.size = 4
1               5   3   1            mutationSize = 5
some text start AAA 111 some text end
some text start BBB 222 some text end
some text start CCC 333 some text end
some text start DDD 111 some text end
some text start EEE 222 some text end */
            StringJoiner sj = new StringJoiner(separator);
            for (int mc = 0; mc < mutationSize; mc++) {
                StringBuilder tmpSb = new StringBuilder();
                for (InternalResolved internalResolved : resolvedList) {
                    Object obj = internalResolved.obj;
                    if (obj instanceof Collection) {
                        List<?> internalList;
                        if(obj instanceof List)
                            internalList = (List<?>) obj;
                        else
                            internalList = new ArrayList<>((Collection<?>) obj); // for .get() by index
                        int internalListSize = internalList.size();
                        if (internalListSize > 0)
                            tmpSb.append(internalList.get(mc % internalListSize));
//                        else
//                            throw new IllegalStateException("Unable to resolve part '" + internalResolved.part + "' " +
//                                    "from '" + template.raw + "' from '" + raw + "', due no values.");
                    } else
                        tmpSb.append(obj);
                }
                sj.add(tmpSb);
            }
            return sj.toString();
        }
    }
    @SuppressWarnings("InnerClassMayBeStatic") // all childs using contextByAlias from outer class
    @ToString
    private class Part {
        protected final String raw;
        protected Part(String raw) {
            this.raw = raw;
        }
        protected String unpack() {
            int length = raw.length();
            if (length >= 2) {
                int startPos = this.getClass() == Part.class ? 0 : 1; // Part.class don't have # or $
                if (raw.charAt(startPos) == '{' && raw.charAt(length - 1) == '}')
                    return raw.substring(startPos + 1, length - 1);
            }
            return raw;
        }
        public Object toObject() {
            return raw;
        }
    }
    @AllArgsConstructor
    private static class InternalResolved {
        private final Object obj;
        private final Part part;
    }
    private static int findEndBracket(StringBuilder target, int startPos) {
        int cnt = 1;
        for (int i = startPos, targetLen = target.length(); i < targetLen; i++) {
            char ch = target.charAt(i);
            if (ch == '{') {
                ++cnt;
            } else if (ch == '}') {
                if (--cnt == 0)
                    return i + 1;
            }
        }
        return -1;
    }
    @Override
    public String toString() {
        return "Template{" +
                "raw='" + raw + '\'' +
                ", internal=" + internal +
                ", parts.size=" + parts.size() +
                ", contextByAlias=" + contextByAlias +
                '}';
    }
}