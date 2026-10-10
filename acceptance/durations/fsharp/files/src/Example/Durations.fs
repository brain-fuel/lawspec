// User-owned LawSpec adapter. A Duration is a System.TimeSpan of whole microseconds.
// ref:DEC-acceptance-with-mutants
module Example.Durations

open System

let remaining (budget: TimeSpan) (spent: TimeSpan) : TimeSpan =
    if spent >= budget then TimeSpan.Zero else budget - spent
