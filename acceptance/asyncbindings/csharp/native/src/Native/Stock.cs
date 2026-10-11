// Application code the warehouse adapters are bound to: some of it
// asynchronous, as a real service client would be.
namespace Warehouse;

using System.Globalization;
using System.Threading.Tasks;

public static class Stock
{
    private static int Price(string sku) =>
        sku == "free" ? 0 : new StringInfo(sku).LengthInTextElements >= 0 ? CodePoints(sku) % 100 : 0;

    private static int CodePoints(string text)
    {
        var count = 0;
        foreach (var _ in text.EnumerateRunes()) count++;
        return count;
    }

    public static Task<int> PriceOf(string sku) => Task.Run(() => Price(sku));

    public static int QuoteOf(string sku) => Price(sku);
}

/// <summary>A stock count that several callers may change.</summary>
public sealed class Shelf
{
    private readonly object gate = new();
    private long total;

    public Task Restock(int amount) => Task.Run(() => { lock (gate) total += amount; });

    public Task<long> Count() => Task.Run(() => { lock (gate) return total; });
}
