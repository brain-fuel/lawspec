package example; public class CanonicalUrl {
static String canonicalize(String x) { return x.replaceAll('/+$', ''); }
}