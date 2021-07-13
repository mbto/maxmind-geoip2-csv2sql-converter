package com.github.mbto.maxmind.geoip2.csv2sql.utils.placeholder;

import lombok.Getter;

import java.lang.reflect.InvocationTargetException;
import java.util.Objects;

@Getter
class ReferenceNode {
    private final String reference;
    private Signature signature;
    private ReferenceNode next;

    public ReferenceNode(String reference) {
        this.reference = reference;
    }

    public void allocateSignature(Object context) throws NoSuchMethodException {
        if (signature == null) {
            signature = ReflectionUtils.extractSignature(context, reference);
        }
    }

    public Object invokeMethod(Object context) throws InvocationTargetException, IllegalAccessException {
        return signature.invokeMethod(context);
    }

    public ReferenceNode setNext(ReferenceNode nextRefNode) {
        this.next = nextRefNode;
        return nextRefNode;
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (o == null || getClass() != o.getClass()) return false;
        ReferenceNode node = (ReferenceNode) o;
        return reference.equals(node.reference) && Objects.equals(next, node.next);
    }

    @Override
    public int hashCode() {
        return Objects.hash(reference, next);
    }

    @Override
    public String toString() {
        StringBuilder sb = new StringBuilder("[");
        ReferenceNode refNode = this;
        int counter = 0;
        do {
            sb.append("ref").append(counter++).append(":'").append(reference).append("' method:");
            if (signature == null || signature.getMethod() == null)
                sb.append("null");
            else
                sb.append('\'').append(signature.getMethod()).append('\'');
            refNode = refNode.next;
            if (refNode == null)
                break;
            sb.append(", ");
        } while (true);
        return sb.append(']').toString();
    }
}