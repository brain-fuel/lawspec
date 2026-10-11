// User-owned LawSpec adapter: async adapters return tasks.
// ref:DEC-acceptance-with-mutants
namespace Example;

using System.Linq;
using System.Threading.Tasks;

public static class Orders
{
    private static int PriceOf(string sku) =>
        sku == "free" ? 0 : sku.EnumerateRunes().Count() % 100;

    public static async Task<int> Price(string sku)
    {
        await Task.Yield();
        return PriceOf(sku);
    }

    public static Task<int> Stock(string sku) => Task.FromResult(sku.EnumerateRunes().Count());

    public static int Quote(string sku) => PriceOf(sku);
}
