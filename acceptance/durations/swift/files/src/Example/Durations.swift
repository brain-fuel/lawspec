// User-owned LawSpec adapter. A Duration is Swift's Duration of whole microseconds.
// ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.Durations {
    static func remaining(_ budget: Duration, _ spent: Duration) -> Duration {
        spent >= budget ? .zero : budget - spent
    }
}
