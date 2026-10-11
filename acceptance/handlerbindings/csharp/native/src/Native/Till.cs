namespace Till;

using System;
using LawSpec.Abilities.ExampleTill;
using LawSpec.Data;

/// <summary>The application's error for a declined card.</summary>
public sealed class CardDeclined() : Exception("declined");

/// <summary>The application's error for an amount it cannot take.</summary>
public sealed class BadAmount(string message) : Exception(message);

/// <summary>A till that keeps what it takes: the production handler.</summary>
public sealed class NativeTill : IDrawer
{
    private long taken;

    public Money Take(Money money)
    {
        taken += money.Cents;
        return new Money(money.Cents);
    }

    public Money Opening() => new(0L);
}

/// <summary>Payments: a bound adapter. It gets its till as the generated interface.</summary>
public static class Payments
{
    public static Money Pay(IDrawer till, long cents)
    {
        if (cents < 0) throw new BadAmount("negative");
        if (cents > 1000) throw new CardDeclined();
        return new Money(till.Take(new Money(cents)).Cents);
    }
}
