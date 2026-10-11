// User-owned LawSpec adapter.
namespace Example;

public static class Slug
{
    public static string Normalize(string x) => x.Replace(" ", "-");
    public static string ReferenceNormalize(string x) => x.Replace(' ', '-');
}
