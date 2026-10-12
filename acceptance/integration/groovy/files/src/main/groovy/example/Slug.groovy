package example; public class Slug {
static String normalize(String x) { return x.replace(' ', '-'); }
static String referenceNormalize(String x) { return x.replace(((char) ' '), ((char) '-')); }
}