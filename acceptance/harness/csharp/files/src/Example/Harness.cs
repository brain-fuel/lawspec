// User-owned LawSpec adapter. ref:REQ-harness-units ref:DEC-tests-cite-requirements
namespace Example;

using LawSpec.Abilities.ExampleHarness;
using LawSpec.Data;

public static class Harness
{
    public static int Discount(Order order) => order.Items > 10 ? order.Total / 10 : 0;

    public static int RoundCents(int cents) => (cents + 4) / 10 * 10;

    public static bool Book(ILedger ledger, int cents) => ledger.Accept(cents);

    /// <summary>The native handler of Ledger: accept.</summary>
    public static ILedger LedgerHandler() => new Ledger();

    private sealed class Ledger : ILedger
    {
        public bool Accept(int cents) => cents > 0;
    }
}
