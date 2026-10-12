// Workflow policies as values: retry strategies and their delays, jitter
// drawn from an explicit SplitMix64 state, the gates a stage passes
// (breakers, rate limits, bulkheads) and the logical failures a stage gives.
// Durations are whole microseconds. The policy's random stream is separate
// from the Random ability's. ref:DEC-domain-modeling-primitives ref:splitmix
// ref:DEC-typed-core-boundary

public enum Policy {
    /// How long to wait before each retry.
    public enum Strategy {
        case immediate
        case fixed(delay: Int64)
        case linear(delay: Int64, step: Int64)
        case exponential(delay: Int64, factor: Int64, cap: Int64?)
        case fibonacci(delay: Int64)
        /// A checked definition decides: attempt (Int), error, previous delay
        /// (a Duration) to a RetryDecision.
        case custom((Value, Value, Value) throws -> Value)
    }

    /// How a delay is randomized.
    public enum Jitter {
        case none
        case full
        case equal
        case decorrelated
    }

    /// Attempts count the first try; zero attempts retries without a bound.
    public struct Retry {
        public let strategy: Strategy
        public let attempts: Int64
        public let jitter: Jitter
        /// Whether an error is worth retrying (a portable Bool).
        public let condition: ((Value) throws -> Value)?
    }

    public enum GateKind: Hashable {
        case breaker
        case limit
        case bulkhead
    }

    /// How long a stage may wait at a gate that answers WaitFor.
    public enum Wait: Equatable {
        case noWait
        case forever
        case within(Int64)
    }

    /// A gate: its state starts at a time, admits at a time (giving the next
    /// state and a Gate decision), and may record how an admitted call ended.
    /// Times are portable Ints, the outcome a portable Bool.
    public struct Gate {
        public let kind: GateKind
        public let start: (Value) throws -> Value
        public let admit: (Value, Value) throws -> Value
        public let finish: ((Value, Value, Value) throws -> Value)?
        public let wait: Wait
    }

    /// A stage's policies, as a definition with a policy declares them.
    public struct StagePolicy {
        public let key: String
        public let stage: String
        public let retry: Retry?
        public let timeout: Int64?
        public let gates: [Gate]
        public let cache: Int64?
        public let compensate: ((Value) throws -> Value)?
        public let wraps: Bool
        /// A further attempt starts after the delay, up to most in all.
        public let hedge: (Int64, Int64)?
    }

    private static func power(_ b: Int64, _ n: Int64) -> Int64 {
        if n == 0 { return 1 }
        if n % 2 == 0 { return power(b &* b, n / 2) }
        return b &* power(b &* b, n / 2)
    }

    private static func fibonacci(_ n: Int64, _ a: Int64, _ b: Int64) -> Int64 {
        var (n, a, b) = (n, a, b)
        while n > 1 {
            (a, b) = (b, a &+ b)
            n -= 1
        }
        return a
    }

    /// The delay before an attempt (from the second) of a strategy.
    public static func retryDelay(_ strategy: Strategy, _ attempt: Int64) throws -> Int64 {
        if attempt < 2 { throw Fail.with("InvalidRetryAttempt", String(attempt)) }
        switch strategy {
        case .immediate: return 0
        case .fixed(let delay): return delay
        case .linear(let delay, let step): return delay &+ step &* (attempt - 2)
        case .exponential(let delay, let factor, let cap):
            let value = delay &* power(factor, attempt - 2)
            return cap.map { Swift.min(value, $0) } ?? value
        case .fibonacci(let delay): return delay &* fibonacci(attempt - 1, 1, 1)
        case .custom: throw Fail.with("CustomRetryDelay", "a custom strategy decides its own delays")
        }
    }

    private static func below(_ bound: Int64, _ state: Random.Seed) -> (Int64, Random.Seed) {
        let (n, next) = Random.below(BigInt(bound), state)
        return (n.exactly(Int64.self) ?? 0, next)
    }

    /// A jittered delay and the next random state.
    public static func jitter(_ kind: Jitter, _ delay: Int64, _ previous: Int64, _ baseDelay: Int64, _ state: Random.Seed) -> (Int64, Random.Seed) {
        switch kind {
        case .none:
            return (delay, state)
        case .full:
            return below(delay + 1, state)
        case .equal:
            let half = delay / 2
            let (r, next) = below(delay - half + 1, state)
            return (half + r, next)
        case .decorrelated:
            let high = Swift.max(baseDelay, previous * 3)
            let (r, next) = below(high - baseDelay + 1, state)
            return (Swift.min(delay, baseDelay + r), next)
        }
    }

    /// A custom strategy's RetryDecision: a delay to wait, or nil to stop.
    public static func retryDecision(_ decision: Value) throws -> Int64? {
        switch decision {
        case .data("lawspec.time::type::RetryDecision::RetryAfter", let fields) where fields.count == 1:
            if case .data(_, let inner) = fields[0], inner.count == 1, case .int(let delay) = inner[0], let d = delay.exactly(Int64.self) {
                return d
            }
        case .data("lawspec.time::type::RetryDecision::Stop", let fields) where fields.isEmpty:
            return nil
        default:
            break
        }
        throw Fail.with("InvalidRetryDecision", "\(decision)")
    }

    /// Whether a stage's result is a failure (a Left).
    public static func failed(_ result: Value) -> Bool {
        if case .data("Either::Left", let fields) = result, fields.count == 1 { return true }
        return false
    }

    /// A stage's own failure: TimedOut, RateLimited, CircuitOpen or Saturated.
    public static func stageFailure(_ kind: String) -> Value {
        .data("Either::Left", [.data("lawspec.resilience::type::StageFailure::" + kind, [])])
    }

    // MARK: Builders, as generated code writes a policy

    public static func immediate() -> Strategy { .immediate }
    public static func fixedDelay(_ delay: Int64) -> Strategy { .fixed(delay: delay) }
    public static func linear(_ delay: Int64, _ step: Int64) -> Strategy { .linear(delay: delay, step: step) }
    public static func exponential(_ delay: Int64, _ factor: Int64, _ cap: Int64?) -> Strategy {
        .exponential(delay: delay, factor: factor, cap: cap)
    }
    public static func fibonacciDelay(_ delay: Int64) -> Strategy { .fibonacci(delay: delay) }
    public static func custom(_ decide: @escaping (Value, Value, Value) throws -> Value) -> Strategy { .custom(decide) }

    /// A jitter by name: none, full, equal or decorrelated.
    public static func jitterOf(_ name: String) -> Jitter {
        switch name {
        case "full": return .full
        case "equal": return .equal
        case "decorrelated": return .decorrelated
        default: return .none
        }
    }

    public static func retry(_ strategy: Strategy, _ attempts: Int64, _ jitter: Jitter, _ condition: ((Value) throws -> Value)?) -> Retry {
        Retry(strategy: strategy, attempts: attempts, jitter: jitter, condition: condition)
    }

    public static func noWait() -> Wait { .noWait }
    public static func forever() -> Wait { .forever }
    public static func within(_ micros: Int64) -> Wait { .within(micros) }

    public static func breaker(_ start: @escaping (Value) throws -> Value, _ admit: @escaping (Value, Value) throws -> Value,
                               _ finish: @escaping (Value, Value, Value) throws -> Value) -> Gate {
        Gate(kind: .breaker, start: start, admit: admit, finish: finish, wait: .noWait)
    }

    public static func limit(_ start: @escaping (Value) throws -> Value, _ admit: @escaping (Value, Value) throws -> Value, _ wait: Wait) -> Gate {
        Gate(kind: .limit, start: start, admit: admit, finish: nil, wait: wait)
    }

    public static func bulkhead(_ start: @escaping (Value) throws -> Value, _ admit: @escaping (Value, Value) throws -> Value,
                                _ finish: @escaping (Value, Value, Value) throws -> Value, _ wait: Wait) -> Gate {
        Gate(kind: .bulkhead, start: start, admit: admit, finish: finish, wait: wait)
    }

    /// A stage's policy.
    public static func stage(_ key: String, _ stage: String, _ retry: Retry?, _ timeout: Int64?, _ gates: [Gate],
                             _ cache: Int64?, _ compensate: ((Value) throws -> Value)?, _ wraps: Bool, _ hedge: (Int64, Int64)?) -> StagePolicy {
        StagePolicy(key: key, stage: stage, retry: retry, timeout: timeout, gates: gates, cache: cache,
                    compensate: compensate, wraps: wraps, hedge: hedge)
    }
}
