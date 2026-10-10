// Application code: a Clock bound in lawspec.json in place of the default
// one. It keeps the default clock's readings.
namespace Example.Clocks

open LawSpec.Abilities.LawspecTime

type SteadyClock() =
    let inner: IClock = LawSpec.DefaultHandlers.clock ()
    let mutable readings = 0L
    interface IClock with
        member _.Now() =
            readings <- readings + 1L
            inner.Now()
        member _.Sleep(duration) = inner.Sleep duration
