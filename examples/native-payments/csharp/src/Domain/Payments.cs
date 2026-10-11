// Application code over the generated payment types: C# binds functions,
// not types, so it uses LawSpec.Data's Money, Currency and Payment.
namespace Domain;

using LawSpec;
using LawSpec.Data;
using Microsoft.FSharp.Collections;
using Microsoft.FSharp.Core;

public static class Payments
{
    private static readonly ExactDecimal Fee = new(2, -1);

    public static Money ApplyFee(Money money) => new(money.Amount + Fee, money.Currency);

    public static Payment Restore(Payment payment) => payment;

    public static FSharpList<FSharpOption<Payment>> Store(FSharpList<FSharpOption<Payment>> payments) => payments;
}
