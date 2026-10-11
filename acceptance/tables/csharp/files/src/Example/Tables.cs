// User-owned LawSpec adapters for the tables example.
// ref:DEC-acceptance-with-mutants
namespace Example;

public static class Tables
{
    public static int ShippingCost(int weight, int distance) => weight * distance + 5 * weight;

    public static string Label(int parcel) => $"parcel {parcel}";
}
