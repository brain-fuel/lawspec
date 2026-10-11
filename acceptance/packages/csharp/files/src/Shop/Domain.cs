// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
namespace Shop;

using LawSpec.Data;

public static class Domain
{
    // One-to-one rates keep the example exact.
    public static Money Convert(ShopDomainCurrency currency, Money money) => new Money(currency, money.Cents);
}
