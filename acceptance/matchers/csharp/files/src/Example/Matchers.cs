// User-owned LawSpec adapters for the matchers example.
// ref:DEC-acceptance-with-mutants
namespace Example;

using System.Linq;
using System.Text.RegularExpressions;
using Microsoft.FSharp.Collections;
using LawSpec.CSharp;
using Order = LawSpec.Data.Order;

public static class Matchers
{
    private static readonly Regex Words = new("[a-z0-9]+");

    public static FSharpList<int> SortItems(FSharpList<int> items) => Fn.ListOf(items.Order());

    public static FSharpList<string> UniqueTags(FSharpList<string> tags) => Fn.ListOf(tags.Distinct());

    public static double Average(int a, int b) => ((double)a + b) / 2.0;

    public static string Slug(string text) =>
        string.Join("-", Words.Matches(text.ToLowerInvariant()).Select(m => m.Value));

    public static Order Ship(int id) => Order.NewShipped(new LawSpec.Data.Recordaaeb2c3925832586ac7d5e3c9a9cd234d3a26f7d9d0e264664a4ae58c6f71911("post", id));
}
