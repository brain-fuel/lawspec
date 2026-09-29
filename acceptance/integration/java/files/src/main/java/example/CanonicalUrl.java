package example; public class CanonicalUrl {
public static String canonicalize(String x) { return x.replaceAll("/+$", ""); }
}