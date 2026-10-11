// Prices the application considers representative: 1.00 to 2.00 euros.
namespace Domain;

using System.Numerics;
using LawSpec;
using LawSpec.CSharp;
using LawSpec.Data;
using LawSpec.Testing;

public static class PaymentGenerators
{
    public static Gen<Money> Prices() =>
        Gen.Map(Fn.F1((int cents) => new Money(new ExactDecimal(new BigInteger(cents), -2), Currency.EUR)), Gen.Range(100, 200));
}
