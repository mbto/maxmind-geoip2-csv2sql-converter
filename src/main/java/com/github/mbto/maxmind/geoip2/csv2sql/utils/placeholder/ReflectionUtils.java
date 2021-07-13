package com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder;

import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;
import java.util.stream.Stream;

public abstract class ReflectionUtils {
    private static final Map<Class<?>, Class<?>> wrapperByPrimitiveClass = new HashMap<>(8, 1f);
    static {
        wrapperByPrimitiveClass.put(boolean.class, Boolean.class);
        wrapperByPrimitiveClass.put(byte.class, Byte.class);
        wrapperByPrimitiveClass.put(short.class, Short.class);
        wrapperByPrimitiveClass.put(char.class, Character.class);
        wrapperByPrimitiveClass.put(int.class, Integer.class);
        wrapperByPrimitiveClass.put(long.class, Long.class);
        wrapperByPrimitiveClass.put(float.class, Float.class);
        wrapperByPrimitiveClass.put(double.class, Double.class);
    }
    public static Object resolveObjectReferenceNode(Object context, ReferenceNode refNode)
            throws InvocationTargetException, IllegalAccessException, NoSuchMethodException {
        if(refNode == null)
            return context;
        do {
            if(refNode.getReference().length() == 0) { // map Collection
                if(!(context instanceof Collection))
                    throw new RuntimeException("Context class not Collection");
                refNode = refNode.getNext();
                Iterator<?> iterator = ((Collection<?>) context).iterator();
                Object firstValue = null;
                if(iterator.hasNext()) {
                    firstValue = iterator.next();
                    refNode.allocateSignature(firstValue);
                }
                if(firstValue == null) {
                    context = Collections.emptyList();
                    continue;
                }
                List<Object> list = new ArrayList<>();
                list.add(refNode.invokeMethod(firstValue));
                while (iterator.hasNext()) {
                    Object value = iterator.next();
                    list.add(refNode.invokeMethod(value));
                }
                context = list;
            } else { // map anyone type
                refNode.allocateSignature(context);
                context = refNode.invokeMethod(context);
            }
        } while ((refNode = refNode.getNext()) != null);
        return context;
    }
    /**
     * https://regex101.com/r/MBpcbE/1
     */
    private static final Pattern methodParamsPattern = Pattern.compile("\"(.*?)(?:\" *, *(?=\"|-?\\d)|(?=\" *$))|(?<!\")(-?\\d+(?:\\.\\d+)?)(?!\")");
    public static Signature extractSignature(Object context, String reference) throws NoSuchMethodException {
        int bkt1 = reference.indexOf("(");
        if (bkt1 == -1) {
            return resolveGetterField(context, new Signature(reference));
        }
        String paramsRaw = reference.substring(bkt1 + 1, reference.lastIndexOf(')'));
        Matcher matcher = methodParamsPattern.matcher(paramsRaw);
        List<Object> args = new ArrayList<>();
        while (matcher.find()) {
            String value = matcher.group(1); // string param
            if(value != null) {
                args.add(value);
                continue;
            }
            value = matcher.group(2); // numeric param
            BigDecimal bigDecimal = new BigDecimal(value);
            Object number;
            try {
                number = bigDecimal.intValueExact();
            } catch (ArithmeticException e) {
                try {
                    number = bigDecimal.longValueExact();
                } catch (ArithmeticException e2) {
                    number = bigDecimal.floatValue();
                }
            }
            args.add(number);
        }
        String methodName = reference.substring(0, bkt1);
        //noinspection ToArrayCallWithZeroLengthArrayArgument
        return resolveMethod(context, new Signature(methodName, args.toArray(new Object[args.size()])));
    }
    static Signature resolveMethod(Object object, Signature signature) throws NoSuchMethodException {
        Class<?> objectClass = object.getClass();
        List<Method> methodCandidates = Stream.of(objectClass.getDeclaredMethods(), objectClass.getMethods())
                .flatMap(Arrays::stream)
                .distinct()
                .filter(availableMethod -> availableMethod.getParameterCount() == signature.getArgs().length
                    && availableMethod.getName().equals(signature.getReference())
                ).collect(Collectors.toList());
        Method method = null;
        int size = methodCandidates.size();
        if(size > 0) {
            method = size == 1 ? methodCandidates.get(0) : searchPolymorphMethod(signature, methodCandidates);
        }
        if(method == null)
            throw new NoSuchMethodException("Method '" + signature.getReference() + "' with "
                    + signature.getArgs().length + " args " + Stream.of(signature.getArgs())
                        .map(arg -> arg.getClass().toString())
                        .collect(Collectors.joining(", ", "[", "]")) + " from class '" + objectClass + "' not founded");
        if (!method.canAccess(object))
            method.setAccessible(true);
        signature.setMethod(method);
        return signature;
    }
    static Method searchPolymorphMethod(Signature signature, List<Method> methodCandidates) {
        Method method = null;
        int methodCounter = 0;
        outer: for (Method methodCandidate : methodCandidates) {
            Class<?>[] parameterTypes = methodCandidate.getParameterTypes();
            int counter = 0;
            for (int i = 0; i < parameterTypes.length; i++) {
                Class<?> parameterClass = parameterTypes[i];
                Class<?> argClass = signature.getArgs()[i].getClass();
                if (parameterClass == argClass
                || (parameterClass.isPrimitive() && wrapperByPrimitiveClass.get(parameterClass) == argClass)) {
                    counter++;
                    continue;
                }
                if (!( // simple search polymorphs
                (parameterClass == Object.class)
             || ((parameterClass == long.class || parameterClass == Long.class) && (argClass == int.class || argClass == Integer.class))
             || ((parameterClass == double.class || parameterClass == Double.class) && (argClass == float.class || argClass == Float.class))
                )) {
                    continue outer;
                }
            }
            if(counter > methodCounter) {
                method = methodCandidate;
                methodCounter = counter;
            }
        }
        return method;
    }
    static Signature resolveGetterField(Object object, Signature signature) throws NoSuchMethodException {
        Class<?> objectClass = object.getClass();
        Field declaredField;
        Class<?> childClass = objectClass;
        do {
            try {
                declaredField = childClass.getDeclaredField(signature.getReference());
                break;
            } catch (Exception ignored) {
                declaredField = null;
            }
        } while ((childClass = childClass.getSuperclass()) != null);
        Class<?> fieldClass = declaredField == null ? null : declaredField.getType();
        boolean isBooleanType = fieldClass == null || fieldClass == boolean.class || fieldClass.isAssignableFrom(Boolean.class);
        Pattern getterPattern = Pattern.compile("(?:get" + (isBooleanType ? "|is" : "") + ")" + signature.getReference(), Pattern.CASE_INSENSITIVE);
        Method getterMethod = Arrays.stream(objectClass.getMethods())
                .filter(availableMethod -> availableMethod.getParameterCount() == 0
                        && getterPattern.matcher(availableMethod.getName()).matches())
                .findFirst()
                .orElseThrow(() -> new NoSuchMethodException("Getter for field '" + signature.getReference() + "' from class '" + objectClass + "' not founded"));
        if (!getterMethod.canAccess(object))
            getterMethod.setAccessible(true);
        signature.setMethod(getterMethod);
        return signature;
    }
    /*public static Object resolveObjectReferences(Object object, String[] references) {
        return resolveObjectReferences(object, references, 0);
    }
    public static Object resolveObjectReferences(Object object, String[] references, int beginIndex) {
        boolean throwIfNoMapping;
        for (int[] pos = {beginIndex}; pos[0] < references.length; ) {
            String reference = references[pos[0]];
            if (pos[0] == 0 || !reference.isEmpty()) {
                object = resolve(object, reference);
                if (++pos[0] == references.length || object == null)
                    return object;
                throwIfNoMapping = false;
            } else
                throwIfNoMapping = true;
            if (object instanceof Map)
                object = mapMap(object, references, pos);
            else if (object instanceof Collection)
                object = mapCollection(object, references, pos);
            else if (throwIfNoMapping)
                throw new IllegalArgumentException("Invalid references '" + String.join(".", references) + "'");
        }
        return object;
    }
    private static Object mapMap(Object object, String[] references, int[] pos) {
        object = resolve(object, references[pos[0]]);
        if (++pos[0] == references.length || object == null)
            return object;
        if (object instanceof Collection) {
            object = mapCollection(object, references, pos);
        }
        return object;
    }
    public static Object mapCollection(Object object, String[] references) {
        return mapCollection(object, references, new int[1]);
    }
    private static Object mapCollection(Object object, String[] references, int[] pos) {
        String reference = references[pos[0]];
        if (reference.isEmpty()) { // next reference apply to all elements in collection
            reference = references[++pos[0]];
            //noinspection rawtypes
            List results = new ArrayList<>();
            for (Object element : (Collection<?>) object) {
                Object mappedValue = resolve(element, reference);
                //noinspection unchecked
                results.add(mappedValue);
            }
            ++pos[0];
            return results;
        }
        object = resolve(object, reference); // reference apply to Collection.class
        ++pos[0];
        return object;
    }*/
}