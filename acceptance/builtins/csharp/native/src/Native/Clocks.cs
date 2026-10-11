// Application code: a Clock bound in lawspec.json in place of the default
// one. It keeps the default clock's readings.
namespace Example.Clocks;

using System;
using LawSpec.Abilities.LawspecTime;
using LawSpec.Data;

public sealed class SteadyClock : IClock
{
    private readonly IClock inner = LawSpec.DefaultHandlers.Clock();
    private long readings;

    public Instant Now()
    {
        readings++;
        return inner.Now();
    }

    public void Sleep(TimeSpan duration) => inner.Sleep(duration);
}
