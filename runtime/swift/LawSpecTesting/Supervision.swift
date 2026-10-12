// Supervision evidence: the generated check of a program with supervisors
// exercises real trees of the runtime's actors, every restart strategy and
// lifetime, restart budgets and escalation, links, committed checkpoints and
// stable mailboxes. ref:DEC-actors-otp-supervision ref:erlang-otp-supervisors

import Foundation
import LawSpecRuntime

public enum Supervision {
    private typealias Handle = Actors.Handle

    private struct Probe: Error, CustomStringConvertible {
        var description: String { "supervision probe" }
    }

    private static func failure(_ label: String, _ expected: Any, _ actual: Any) -> LawSpecError {
        Fail.with("SupervisionFailed", "\(label): expected \(expected), actual \(actual)")
    }

    private static func expect<T: Equatable>(_ label: String, _ expected: T, _ actual: T) throws {
        if expected != actual { throw failure(label, expected, actual) }
    }

    private static func counter() -> Actors.Spec { Actors.actor({ 0 }, { _ in 0 }) }

    private static func counters(_ names: [String]) -> [(String, Actors.Lifetime, Actors.Spec)] {
        names.map { ($0, .permanent, counter()) }
    }

    private static func tree(_ strategy: Actors.Strategy, _ limit: Int, _ children: [(String, Actors.Lifetime, Actors.Spec)],
                             _ body: (Handle) throws -> Void) throws {
        try Actors.withSpec(try Actors.supervisor(strategy, limit, 10_000_000, children), body)
    }

    private static func value(_ h: Handle) throws -> Int { try Actors.state(h) as! Int }

    private static func states(_ handles: [Handle]) throws -> [Int] { try handles.map(value) }

    @discardableResult
    private static func bump(_ h: Handle) throws -> Int {
        try Actors.call(h) { s in
            let n = (s as! Int) + 1
            return (n, n)
        } as! Int
    }

    private static func failCall(_ h: Handle) throws {
        do {
            let answer = try Actors.call(h) { _ in throw Probe() }
            throw failure("failing handler", "ActorCrashed", answer)
        } catch let e as LawSpecError where e.code == "ActorCrashed" && e.detail.contains("supervision probe") {
            return
        } catch let e as LawSpecError where e.code == "SupervisionFailed" {
            throw e
        } catch {
            throw failure("failing handler", "ActorCrashed", error)
        }
    }

    private static func stopped(_ h: Handle) throws {
        do {
            let s = try Actors.state(h)
            throw failure("stopped actor", "ActorStopped", s)
        } catch let e as LawSpecError where e.code == "ActorStopped" {
            return
        } catch let e as LawSpecError where e.code == "SupervisionFailed" {
            throw e
        } catch {
            throw failure("stopped actor", "ActorStopped", error)
        }
    }

    private static func crashed(_ inbox: Actors.Inbox, _ h: Handle) throws {
        guard case .crashed? = Actors.receiveEvent(inbox, h, 2000) else { throw failure("crash monitor", "Crashed", "nothing") }
    }

    private static func waitFor(_ label: String, _ signal: DispatchSemaphore) throws {
        if signal.wait(timeout: .now() + 2) == .timedOut { throw failure(label, "signal", "timeout") }
    }

    private static func strategies() throws {
        for (strategy, expected) in [(Actors.Strategy.oneForOne, [1, 0, 1]), (.oneForAll, [0, 0, 0]), (.restForOne, [1, 0, 0])] {
            try tree(strategy, 5, counters(["a", "b", "c"])) { sup in
                let actors = try ["a", "b", "c"].map { try Actors.child(sup, $0) }
                let before = actors.map(Actors.worker)
                for a in actors { try bump(a) }
                try expect("three children", 3, Actors.children(sup).count)
                try failCall(actors[1])
                try expect("\(strategy)", expected, try states(actors))
                let after = actors.map(Actors.worker)
                try expect("\(strategy) replaced workers", expected.map { $0 == 0 }, zip(before, after).map { $0 != $1 })
            }
        }
    }

    private static func lifetimes() throws {
        try tree(.oneForOne, 5, [("p", .permanent, counter()), ("t", .transient, counter()), ("x", .temporary, counter())]) { sup in
            let p = try Actors.child(sup, "p")
            let t = try Actors.child(sup, "t")
            let x = try Actors.child(sup, "x")
            try bump(p)
            Actors.stop(p)
            try expect("permanent normal stop", 0, try value(p))
            try bump(t)
            try failCall(t)
            try expect("transient crash", 0, try value(t))
            Actors.stop(t)
            try stopped(t)
            try failCall(x)
            try stopped(x)
            try expect("remaining children", ["p"], Actors.children(sup).map(\.0))
        }
    }

    private static func limits() throws {
        try tree(.oneForOne, 2, counters(["a", "b"])) { sup in
            let a = try Actors.child(sup, "a")
            let b = try Actors.child(sup, "b")
            let inbox = Actors.Inbox()
            Actors.monitor(sup, inbox)
            for _ in 1...3 { try failCall(a) }
            try stopped(b)
            try crashed(inbox, sup)
            try expect("one limit notification", true, Actors.receiveEvent(inbox, sup, 0) == nil)
        }
    }

    private static func escalation() throws {
        let inner = try Actors.supervisor(.oneForOne, 1, 10_000_000, counters(["a", "b"]))
        try tree(.oneForOne, 5, [("inner", .permanent, inner), ("c", .permanent, counter())]) { sup in
            let innerHandle = try Actors.child(sup, "inner")
            let c = try Actors.child(sup, "c")
            let a = try Actors.child(innerHandle, "a")
            let b = try Actors.child(innerHandle, "b")
            let old = Actors.worker(innerHandle)
            try bump(b)
            try bump(c)
            try failCall(a)
            try failCall(a)
            try expect("escalated children", [0, 0, 1], try states([a, b, c]))
            try expect("replaced inner supervisor", true, old != Actors.worker(innerHandle))
            try expect("outer restart count", 1, Actors.restartCount(sup))
            try expect("fresh inner budget", 0, Actors.restartCount(innerHandle))
        }
    }

    private static func links() throws {
        try Actors.withSpec(counter()) { a in
            try Actors.withSpec(counter()) { b in
                Actors.link(a, b)
                let inbox = Actors.Inbox()
                Actors.monitor(b, inbox)
                try failCall(a)
                try crashed(inbox, b)
                try stopped(b)
            }
        }
        try tree(.oneForOne, 10, counters(["a", "b", "c"])) { sup in
            let actors = try ["a", "b", "c"].map { try Actors.child(sup, $0) }
            Actors.link(actors[0], actors[1])
            Actors.link(actors[1], actors[2])
            Actors.link(actors[2], actors[0])
            let inbox = Actors.Inbox()
            for x in actors {
                try bump(x)
                Actors.monitor(x, inbox)
            }
            try failCall(actors[0])
            for x in actors { try crashed(inbox, x) }
            let deadline = Date().addingTimeInterval(2)
            while Actors.restartCount(sup) < 3 && Date() < deadline { usleep(1000) }
            try expect("link cycle", [0, 0, 0], try states(actors))
            try expect("one restart per linked actor", 3, Actors.restartCount(sup))
        }
    }

    private static func checkpointAndMailbox() throws {
        let spec = Actors.actor({ 0 }, { $0 })
        try tree(.oneForOne, 5, [("a", .permanent, spec)]) { sup in
            let a = try Actors.child(sup, "a")
            try bump(a)
            try failCall(a)
            try expect("committed checkpoint", 1, try value(a))
            let entered = DispatchSemaphore(value: 0)
            let finish = DispatchSemaphore(value: 0)
            defer { finish.signal() }
            let inbox = Actors.Inbox()
            Actors.monitor(a, inbox)
            let w = Actors.worker(a)
            try Actors.tell(a) { s in
                entered.signal()
                finish.wait()
                finish.signal()
                return ((), (s as! Int) + 10)
            }
            try waitFor("mailbox handler started", entered)
            try Actors.tell(a) { s in ((), (s as! Int) + 2) }
            Actors.kill(a)
            try crashed(inbox, a)
            try expect("queued tell after an external kill", 3, try value(a))
            try expect("stable mailbox handle", a, try Actors.child(sup, "a"))
            try expect("replaced killed worker", true, w != Actors.worker(a))
        }
    }

    private static func queuedSiblingRestart(_ strategy: Actors.Strategy) throws {
        let restored = Locked<Int?>(nil)
        let sibling = Actors.actor({ 0 }, { s in
            restored.with { $0 = s as? Int }
            return 0
        })
        try tree(strategy, 5, [("a", .permanent, counter()), ("b", .permanent, sibling)]) { sup in
            let a = try Actors.child(sup, "a")
            let b = try Actors.child(sup, "b")
            let entered = DispatchSemaphore(value: 0)
            let finish = DispatchSemaphore(value: 0)
            defer { finish.signal() }
            let queued = Locked<Int?>(nil)
            try Actors.tell(b) { s in
                entered.signal()
                finish.wait()
                finish.signal()
                return ((), (s as! Int) + 1)
            }
            try waitFor("sibling started", entered)
            try Actors.tell(b) { s in
                queued.with { $0 = s as? Int }
                return ((), (s as! Int) + 3)
            }
            try Actors.tell(a) { _ in throw Probe() }
            let deadline = Date().addingTimeInterval(2)
            while Actors.restartCount(sup) == 0 {
                if Date() > deadline { throw failure("restart admitted", true, false) }
                usleep(1000)
            }
            // This tell follows the restart; the two accepted earlier belong
            // to the old checkpoint, and their order survives the restart.
            try Actors.tell(b) { s in ((), (s as! Int) + 10) }
            finish.signal()
            try expect("\(strategy) post-restart tell", 10, try value(b))
            try expect("\(strategy) queued checkpoint", 1, queued.with { $0 })
            try expect("\(strategy) restart checkpoint", 4, restored.with { $0 })
        }
    }

    /// The supervision check: fails with SupervisionFailed naming what broke.
    public static func check() throws {
        try Actors.withSpec(counter()) { a in
            try expect("initial increment", 1, try bump(a))
            try failCall(a)
            try stopped(a)
        }
        try strategies()
        try lifetimes()
        try limits()
        try escalation()
        try links()
        try checkpointAndMailbox()
        for strategy in [Actors.Strategy.oneForAll, .restForOne] { try queuedSiblingRestart(strategy) }
    }
}
