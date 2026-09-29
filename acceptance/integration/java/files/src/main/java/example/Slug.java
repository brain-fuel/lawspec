package example; public class Slug {
public static String normalize(String x) { return x.replace(" ", "-"); }
public static String referenceNormalize(String x) { return x.replace(' ', '-'); }
}