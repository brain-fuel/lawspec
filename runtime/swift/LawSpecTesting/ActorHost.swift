// The actor runtime as an actor model's system: one permanent child under a
// one-for-one supervisor whose restart budget is the run's length, so
// injected crashes cannot exhaust it. ref:DEC-actors-otp-supervision
// ref:DEC-stateful-models-linearizability

import LawSpecRuntime

/// The host actor models run on.
public enum ActorHost {
    /// Start one permanent child under a one-for-one supervisor that allows
    /// the given number of restarts, run the body with the child, then stop.
    /// start makes the first state; restart makes a state from the state at
    /// the crash.
    public static func withActor<R>(_ restarts: Int, _ start: @escaping () throws -> Value, _ restart: @escaping (Value) throws -> Value,
                                    _ body: (Actors.Handle) throws -> R) throws -> R {
        let spec = try Actors.supervisor(.oneForOne, max(1, restarts), 1_000_000, [
            ("model", .permanent, Actors.actor({ try start() }, { state in try restart(state as! Value) })),
        ])
        return try Actors.withSpec(spec) { supervisor in try body(try Actors.child(supervisor, "model")) }
    }

    /// Run an update on the actor's state in the actor: its reply and next state.
    public static func call(_ actor: Actors.Handle, _ update: @escaping (Value) throws -> (Value, Value)) throws -> Value {
        try Actors.call(actor) { state in
            let (reply, next) = try update(state as! Value)
            return (reply, next)
        } as! Value
    }

    /// Crash the actor, waiting until its supervisor has restarted it.
    public static func crash(_ actor: Actors.Handle) throws { try Actors.crash(actor) }

    /// The actor's current state.
    public static func state(_ actor: Actors.Handle) throws -> Value { try Actors.state(actor) as! Value }
}
