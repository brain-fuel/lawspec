// User-owned LawSpec adapter.
namespace Example.Mixed;

public static class Inputs
{
    public static string Normalize(string x) => x.Replace(" ", "-");
    public static int Identity(int x) => x;
}
