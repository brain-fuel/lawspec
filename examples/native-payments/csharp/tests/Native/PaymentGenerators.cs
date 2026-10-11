// Prices the application considers representative: 1.00 to 2.00 euros.
namespace Domain;

using System.Numerics;
using FsCheck;
using FsCheck.Fluent;
using LawSpec;
using LawSpec.Data;

public static class PaymentGenerators
{
    public static Arbitrary<Money> Prices() =>
        Arb.From(Gen.Choose(100, 200).Select(cents => new Money(new ExactDecimal(new BigInteger(cents), -2), Currency.EUR)));
}
