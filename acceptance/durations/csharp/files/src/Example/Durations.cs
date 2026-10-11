// User-owned LawSpec adapter. A Duration is a System.TimeSpan of whole microseconds.
// ref:DEC-acceptance-with-mutants
namespace Example;

using System;

public static class Durations
{
    public static TimeSpan Remaining(TimeSpan budget, TimeSpan spent) =>
        spent >= budget ? TimeSpan.Zero : budget - spent;
}
