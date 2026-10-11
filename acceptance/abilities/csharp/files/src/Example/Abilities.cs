// User-owned LawSpec adapter: a native Gateway handler and a native adapter
// that uses Gateway through the handler it is given.
// ref:DEC-acceptance-with-mutants
namespace Example;

using LawSpec.Abilities.ExampleAbilities;
using LawSpec.Data;

public static class Abilities
{
    public static bool Charge(IGateway gateway, int cents) =>
        gateway.Authorize(cents) is Payment.Approved approved
            && gateway.Capture(approved.cents).Cents == cents;

    /// <summary>The native handler of Gateway: authorize, capture, fee.</summary>
    public static IGateway GatewayHandler() => new Gateway();

    private sealed class Gateway : IGateway
    {
        public Payment Authorize(int cents) => cents < 0 ? Payment.Declined : Payment.NewApproved(cents);

        public Receipt Capture(int cents) => new Receipt(cents);

        public int Fee() => 25;
    }
}
