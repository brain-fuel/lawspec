// User-owned LawSpec adapter.
namespace Example;

public static class CanonicalUrl
{
    public static string Canonicalize(string x) => x.TrimEnd('/');
}
