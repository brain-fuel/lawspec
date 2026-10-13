// Checked scenario programs run real concurrent processes, carrying vector
// clocks with messages and joining every child before the final checks.
// ref:DEC-sessions-by-construction ref:DEC-stateful-models-linearizability
// ref:DEC-portable-seeded-generation

import Foundation
import LawSpecRuntime

public enum Scenario {
    public typealias Descriptor = Descriptors.Descriptor

    /// A step of a scenario process.
    public indirect enum Act {
        case call(String, String?, [Descriptor])
        case send(String, Descriptor)
        case receive(String, String)
        case receiveOr(String, String, [Act])
        case par([(Int, [Act])])
        case expect(String, Descriptor)
    }

    /// A scenario program: its channels, mailboxes and root process; the
    /// branches a crash schedule may select (identity, length); its wire forms.
    public struct Program {
        public let title: String
        public let channels: [String]
        public let mailboxes: [String]
        public let acts: [Act]
        public let branches: [(Int, Int)]
        public let wire: [Descriptor]?
    }

    /// How scenarios run: cases and seed for check; and for one run, the receive
    /// timeout (ms), whether values cross a network, whether a process crashes
    /// (or which, at which step), network faults and the network deadline (ms).
    public struct Options {
        public var cases = 30
        public var seed: BigInt?
        public var receiveTimeout = 5000
        public var network = false
        public var crash = false
        public var victim: (Int, Int)?
        public var faults: (MemoryOptions) -> MemoryOptions = { $0 }
        public var deadline = 5000
        public init() {}
    }

    /// The default options.
    public static var defaults: Options { Options() }

    /// A run's report.
    public struct Report {
        public let title: String
        public var history: [History.Event]
        public var outcome: String
        public var clock: ScenarioClock
        public let shake: BigInt
        public var victim: (Int, Int)?
        public var network: ScenarioStats?
        public var final: Value?
        public var reason: String?
    }

    private static func fail(_ code: String, _ detail: String = "") -> LawSpecError { Fail.with(code, detail) }

    private static func message(_ error: any Error) -> String {
        if let e = error as? LawSpecError { return e.description }
        return "\(type(of: error)): \(error)"
    }

    private static func name(_ d: Descriptor) throws -> String {
        switch d {
        case .atom(let a): return a
        case .quoted(let q): return q
        default: throw fail("InvalidScenario", "\(d)")
        }
    }

    private static func annotate(_ acts: [Descriptor], _ next: Int, _ eligible: Bool) throws -> ([Act], Int, [(Int, Int)]) {
        var result = [Act]()
        var n = next
        var found = [(Int, Int)]()
        for act in acts {
            let (a, n1, b1) = try annotateAct(act, n, eligible)
            result.append(a)
            n = n1
            found += b1
        }
        return (result, n, found)
    }

    private static func annotateAct(_ act: Descriptor, _ next: Int, _ eligible: Bool) throws -> (Act, Int, [(Int, Int)]) {
        guard case .forms(let parts) = act, let head = parts.first, case .atom(let verb) = head else {
            throw fail("InvalidScenario", "\(act)")
        }
        let args = Array(parts.dropFirst())
        switch verb {
        case "par":
            var branches = [(Int, [Act])]()
            var n = next
            var found = [(Int, Int)]()
            for branch in args {
                guard case .forms(let bparts) = branch, let bhead = bparts.first, case .atom("process") = bhead else {
                    throw fail("InvalidScenario", "\(branch)")
                }
                let body = Array(bparts.dropFirst())
                let id = n
                let (acts, n1, b1) = try annotate(body, n + 1, eligible)
                branches.append((id, acts))
                found += (eligible ? [(id, body.count)] : []) + b1
                n = n1
            }
            return (.par(branches), n, found)
        case "receiveor" where args.count == 3:
            guard case .forms(let bparts) = args[2], let bhead = bparts.first, case .atom("process") = bhead else {
                throw fail("InvalidScenario", "\(act)")
            }
            let (acts, n, _) = try annotate(Array(bparts.dropFirst()), next, false)
            return (.receiveOr(try name(args[0]), try name(args[1]), acts), n, [])
        case "call" where args.count >= 2:
            let bound: String?
            switch args[1] {
            case .hole, .atom("_"): bound = nil
            default: bound = try name(args[1])
            }
            return (.call(try name(args[0]), bound, Array(args.dropFirst(2))), next, [])
        case "send" where args.count == 2: return (.send(try name(args[0]), args[1]), next, [])
        case "receive" where args.count == 2: return (.receive(try name(args[0]), try name(args[1])), next, [])
        case "expect" where args.count == 2: return (.expect(try name(args[0]), args[1]), next, [])
        default: throw fail("InvalidScenario", "\(act)")
        }
    }

    /// Read a program's text. Stable identities follow source order; pars inside
    /// or-else handlers are real processes too, but crash schedules skip them.
    public static func read(_ spec: String) throws -> Program {
        let forms = try Descriptors.read(spec)
        func find(_ key: String) -> [Descriptor]? {
            for f in forms {
                if case .forms(let parts) = f, let head = parts.first, case .atom(let k) = head, k == key { return Array(parts.dropFirst()) }
            }
            return nil
        }
        guard case .forms(let first)? = forms.first, first.count >= 2, case .atom("scenario") = first[0] else {
            throw fail("InvalidScenario", "scenario")
        }
        let title = try name(first[1])
        let (acts, _, branches) = try annotate(find("process") ?? [], 1, true)
        return Program(title: title, channels: try (find("channels") ?? []).map(name), mailboxes: try (find("mailboxes") ?? []).map(name),
                       acts: acts, branches: branches, wire: find("wire"))
    }

    /// The process a crash schedule stops, and before which of its steps.
    public static func victim(_ program: Program, _ shake: BigInt) -> (Int, Int)? {
        if program.branches.isEmpty { return nil }
        let r0 = Random.seed(shake ^ BigInt(UInt64(0xc3a5c85c97cb3127)))
        let (i, r1) = Random.below(BigInt(program.branches.count), r0)
        let (identity, length) = program.branches[Int(i.truncated(Int64.self))]
        let (at, _) = Random.below(BigInt(length + 1), r1)
        return (identity, Int(at.truncated(Int64.self)))
    }

    /// Each case's shake, and whether it runs over a network or with a crash.
    public static func schedules(_ seed: BigInt, _ runs: Int) -> [(BigInt, (Bool, Bool))] {
        var random = Random.seed(seed ^ BigInt(UInt64(0x2545f4914f6cdd1d)))
        return (0..<max(0, runs)).map { i in
            let (shake, next) = Random.next(random)
            random = next
            return (BigInt(shake), (i % 3 == 1, i % 3 == 2))
        }
    }

    private final class Setup: @unchecked Sendable {
        let program: Program
        let model: Model.Machine
        let context: Model.Context
        let system: Any
        let hub: ScenarioHub
        let history = Locked<[Int64: History.Event]>([:])
        let failure = Locked<String?>(nil)
        let ticks = Locked<Int64>(0)
        let commands: [String: Int]
        let shake: BigInt
        let victim: (Int, Int)?
        let timeout: Int

        init(_ program: Program, _ model: Model.Machine, _ context: Model.Context, _ system: Any, _ hub: ScenarioHub,
             _ shake: BigInt, _ victim: (Int, Int)?, _ timeout: Int) {
            self.program = program
            self.model = model
            self.context = context
            self.system = system
            self.hub = hub
            var commands = [String: Int]()
            for (i, c) in model.commands.enumerated() { commands[c.name] = i }
            self.commands = commands
            self.shake = shake
            self.victim = victim
            self.timeout = timeout
        }

        func tick() -> Int64 { ticks.with { $0 += 1; return $0 } }
    }

    private struct State {
        let id: String
        var values: [String: Value]
        var ends: [String: ScenarioDestination]
        var clock: ScenarioClock
        var random: Random.Seed
        var crashable: Bool
    }

    private static func value(_ operand: Descriptor, _ values: [String: Value]) throws -> Value {
        if case .forms(let parts) = operand, parts.count == 2, case .atom(let kind) = parts[0] {
            switch (kind, parts[1]) {
            case ("var", let n):
                guard let v = values[try name(n)] else { throw fail("InvalidScenario", "\(operand)") }
                return v
            case ("int", .number(let n)): return .int(n)
            case ("bool", let b): return .bool(try name(b) == "true")
            case ("text", let t): return .text(try name(t))
            case ("tag", let t): return .data(try name(t), [])
            default: break
            }
        }
        throw fail("InvalidScenario", "\(operand)")
    }

    private static func bump(_ state: State) -> State {
        var next = state
        next.clock[state.id] = (state.clock[state.id] ?? 0) + 1
        return next
    }

    private static func mergeClock(_ a: ScenarioClock, _ b: ScenarioClock) -> ScenarioClock {
        var acc = a
        for (p, n) in b { acc[p] = max(acc[p] ?? 0, n) }
        return acc
    }

    private static func perturb(_ state: State) -> State {
        let (choice, next) = Random.below(BigInt(4), state.random)
        switch choice.truncated(Int64.self) {
        case 0: break
        case 1: Thread.sleep(forTimeInterval: 0)
        default: Thread.sleep(forTimeInterval: 0.001)
        }
        var made = state
        made.random = next
        return made
    }

    private static func names(_ acts: [Act]) -> [String] {
        var found = [String]()
        for act in acts {
            switch act {
            case .send(let n, let operand):
                found.append(n)
                if case .forms(let parts) = operand, parts.count == 2, case .atom("var") = parts[0], let v = try? name(parts[1]) {
                    found.append(v)
                }
            case .receive(let n, _): found.append(n)
            case .receiveOr(let n, _, let handler): found += [n] + names(handler)
            case .par(let branches): for (_, body) in branches { found += names(body) }
            default: break
            }
        }
        return Array(Set(found)).sorted { Scalar.compareText($0, $1) < 0 }
    }

    private static func countSends(_ acts: [Act], _ target: String) -> Int {
        acts.reduce(0) { total, act in
            switch act {
            case .send(let n, _) where n == target: return total + 1
            case .par(let branches): return total + branches.reduce(0) { $0 + countSends($1.1, target) }
            default: return total
            }
        }
    }

    private static func sends(_ acts: [Act], _ boxes: [String]) -> [String: Int] {
        var result = [String: Int]()
        for n in boxes { result[n] = countSends(acts, n) }
        return result
    }

    private static func receives(_ acts: [Act], _ target: String) -> Bool {
        acts.contains { act in
            switch act {
            case .receive(let n, _): return n == target
            case .par(let branches): return branches.contains { receives($0.1, target) }
            default: return false
            }
        }
    }

    /// Each branch's ends: those its parent passes on, or a side of a channel the
    /// branch is the first or second to use.
    private static func divide(_ branches: [(Int, [Act])], _ channels: [String], _ ends: [String: ScenarioDestination])
        -> ([(Int, [Act], [String: ScenarioDestination])], [String: ScenarioDestination]) {
        var users = [String: [Int]]()
        for (i, branch) in branches.enumerated() {
            for n in names(branch.1) { users[n, default: []].append(i) }
        }
        var remaining = ends
        var plans = [(Int, [Act], [String: ScenarioDestination])]()
        for (i, (id, body)) in branches.enumerated() {
            var mine = [String: ScenarioDestination]()
            for n in names(body) {
                if let e = remaining[n] {
                    mine[n] = e
                    remaining[n] = nil
                } else if channels.contains(n) {
                    let side = users[n]!.prefix { $0 != i }.count
                    mine[n] = .endOf(n, side)
                }
            }
            plans.append((id, body, mine))
        }
        return (plans, remaining)
    }

    private static func destination(_ setup: Setup, _ target: String, _ state: State) throws -> ScenarioDestination {
        if setup.program.mailboxes.contains(target) { return .mailboxOf(target) }
        guard let d = state.ends[target] else { throw fail("InvalidScenario", "no end " + target) }
        return d
    }

    private static func give(_ operand: Descriptor, _ state: State) throws -> (ScenarioPayload, State) {
        if case .forms(let parts) = operand, parts.count == 2, case .atom("var") = parts[0] {
            let n = try name(parts[1])
            if case .endOf(let c, let s)? = state.ends[n] {
                var next = state
                next.ends[n] = nil
                return (.moved(c, s), next)
            }
            return (.plain(try value(operand, state.values)), state)
        }
        return (.plain(try value(operand, [:])), state)
    }

    private enum Step {
        case next(State)
        case finish(String, State)
    }

    private static func steps(_ setup: Setup, _ acts: [Act], _ state: State) throws -> (String, State) {
        var current = state
        for (index, act) in acts.enumerated() {
            let interrupted = setup.failure.with({ $0 }) != nil
                || (current.crashable && setup.victim.map { "\($0.0)" == current.id && $0.1 == index } == true)
            if interrupted { return ("failed", current) }
            switch try perform(setup, act, current) {
            case .next(let next): current = next
            case .finish(let outcome, let last): return (outcome, last)
            }
        }
        let interrupted = setup.failure.with({ $0 }) != nil
            || (current.crashable && setup.victim.map { "\($0.0)" == current.id && $0.1 == acts.count } == true)
        return (interrupted ? "failed" : "done", current)
    }

    private static func perform(_ setup: Setup, _ act: Act, _ state: State) throws -> Step {
        switch act {
        case .call(let command, let bound, let operands):
            guard let index = setup.commands[command] else { throw fail("InvalidScenario", "command " + command) }
            let step = try Model.command(setup.model, index)
            let args = try operands.map { try value($0, state.values) }
            let s1 = bump(perturb(state))
            let called = setup.tick()
            let (result, _) = try Model.invoke(setup.model, setup.context, step, args, setup.system)
            let returned = setup.tick()
            var s2 = bump(s1)
            let event = History.Event(command: index, arguments: args, result: result, called: called, returned: returned,
                                      process: state.id, callClock: s1.clock, returnClock: s2.clock)
            setup.history.with { $0[called] = event }
            if let bound { s2.values[bound] = result }
            return .next(s2)
        case .send(let target, let operand):
            let d = try destination(setup, target, state)
            let (payload, s1) = try give(operand, state)
            let s2 = bump(perturb(s1))
            try setup.hub.send(state.id, d, payload, s2.clock)
            return .next(s2)
        case .receive(let source, let variable):
            return try accept(setup, source, variable, nil, state)
        case .receiveOr(let source, let variable, let handler):
            return try accept(setup, source, variable, handler, state)
        case .par(let branches):
            let program = setup.program
            let (plans, ends) = divide(branches, program.channels, state.ends)
            let children = plans.map { (id, body, mine) in
                ScenarioChild(id: "\(id)", ends: mine.keys.sorted().map { mine[$0]! }, sends: sends(body, program.mailboxes),
                              receives: program.mailboxes.filter { receives(body, $0) })
            }
            try setup.hub.fork(state.id, children)
            let outcomes = Locked([(String, ScenarioClock)?](repeating: nil, count: plans.count))
            let group = DispatchGroup()
            for (i, plan) in plans.enumerated() {
                let random = Random.seed(setup.shake ^ (BigInt(i + 1) * BigInt(UInt64(0x9e3779b97f4a7c15))))
                let work = UncheckedBox((plan, state.values, state.clock))
                group.enter()
                LawThread.start {
                    let ((id, body, mine), values, clock) = work.value
                    let outcome = run(setup, "\(id)", body, values, mine, clock, random)
                    outcomes.with { $0[i] = outcome }
                    group.leave()
                }
            }
            group.wait()
            let results = outcomes.with { $0 }.map { $0! }
            var next = state
            next.ends = ends
            next.clock = results.reduce(state.clock) { mergeClock($0, $1.1) }
            next = bump(next)
            return results.contains { $0.0 == "failed" } ? .finish("failed", next) : .next(next)
        case .expect(let variable, let constant):
            guard let actual = state.values[variable] else { throw fail("InvalidScenario", "unbound " + variable) }
            let wanted = try value(constant, [:])
            if Scalar.equal(actual, wanted) { return .next(state) }
            throw fail("ScenarioExpectation", "\(variable) is \(Recorded.debug(actual)), expected \(Recorded.debug(wanted))")
        }
    }

    private static func accept(_ setup: Setup, _ source: String, _ variable: String, _ handler: [Act]?, _ state: State) throws -> Step {
        let d = try destination(setup, source, state)
        switch try setup.hub.receive(state.id, d, setup.timeout) {
        case .senderGone:
            guard let acts = handler else { return .finish("failed", state) }
            if case .endOf = d { try setup.hub.abandon(state.id, d) }
            var next = state
            next.ends[source] = nil
            next.crashable = false
            let (outcome, last) = try steps(setup, acts, next)
            return .finish(outcome, last)
        case .arrived(let payload, let sent):
            var next = state
            next.clock = mergeClock(state.clock, sent)
            next = bump(next)
            switch payload {
            case .moved(let c, let s): next.ends[variable] = .endOf(c, s)
            case .plain(let v): next.values[variable] = v
            }
            return .next(next)
        }
    }

    private static func run(_ setup: Setup, _ id: String, _ acts: [Act], _ values: [String: Value], _ ends: [String: ScenarioDestination],
                            _ clock: ScenarioClock, _ random: Random.Seed) -> (String, ScenarioClock) {
        defer { try? setup.hub.leave(id) }
        do {
            if id != "root" { try setup.hub.enter(id) }
            let state = State(id: id, values: values, ends: ends, clock: clock, random: random, crashable: true)
            let (outcome, last) = try steps(setup, acts, state)
            return (outcome, last.clock)
        } catch {
            let text = "process \(id) raised \(message(error))"
            setup.failure.with { if $0 == nil { $0 = text } }
            return ("failed", clock)
        }
    }

    /// Run a program once with a shake; its report, as a success or a failure.
    public static func runOnce(_ model: Model.Machine, _ program: Program, _ shake: BigInt, _ options: Options) -> Result<Report, ReportFailure> {
        func failed(_ reason: String) -> Result<Report, ReportFailure> {
            .failure(ReportFailure(report: Report(title: program.title, history: [], outcome: "failed", clock: [:], shake: shake,
                                                  victim: nil, network: nil, final: nil, reason: reason)))
        }
        do {
            if !model.shared { throw fail("ScenarioRequiresSharedModel", model.name) }
            let chosen = options.victim ?? (options.crash ? victim(program, shake) : nil)
            if let (id, at) = chosen {
                guard let (_, length) = program.branches.first(where: { $0.0 == id }), at >= 0, at <= length else {
                    throw fail("InvalidScenarioVictim", "\(id) \(at)")
                }
            }
            let start = try model.startArguments.map { try Descriptors.minimal($0, model.table) }
            return try Model.withSystem(model, start, 0) { context, system, expected in
                let io = ScenarioIoOptions(network: options.network, wire: program.wire, shake: shake, faults: options.faults,
                                           deadline: options.deadline)
                return try ScenarioIo.withIo(program.channels, sends(program.acts, program.mailboxes), io) { hub in
                    let setup = Setup(program, model, context, system, hub, shake, chosen, options.receiveTimeout)
                    let (outcome, clock) = run(setup, "root", program.acts, [:], [:], [:], Random.seed(shake))
                    let events = setup.history.with { $0 }.sorted { $0.key < $1.key }.map { $0.value }
                    var report = Report(title: program.title, history: events, outcome: outcome, clock: clock, shake: shake,
                                        victim: chosen, network: try hub.networkStats(), final: nil, reason: nil)
                    if let failure = setup.failure.with({ $0 }) {
                        report.reason = failure
                        return .failure(ReportFailure(report: report))
                    }
                    if outcome == "failed" && chosen == nil {
                        report.reason = "process_failed"
                        return .failure(ReportFailure(report: report))
                    }
                    let final = try model.abstractRun.map { try Model.callback($0, context, [try Model.systemState(model, system)]) }
                    report.final = final
                    if History.consistent(model, context, events, expected, final, system) { return .success(report) }
                    report.reason = "no_consistent_order"
                    return .failure(ReportFailure(report: report))
                }
            }
        } catch {
            return failed(message(error))
        }
    }

    /// A failed run's report.
    public struct ReportFailure: Error, @unchecked Sendable {
        public let report: Report
    }

    /// Run a program text once with a shake: nil, or why it failed.
    public static func execute(_ model: Model.Machine, _ spec: String, _ shake: BigInt, _ options: Options) throws -> Report? {
        switch runOnce(model, try read(spec), shake, options) {
        case .success: return nil
        case .failure(let f): return f.report
        }
    }

    private static func describe(_ victim: (Int, Int)?) -> String {
        guard let (id, at) = victim else { return "none" }
        return "(\(id), \(at))"
    }

    /// Check a scenario over its cases: plain, over a faulty network, and with a
    /// crash, in turn; the first failure is raised with its seed and shake.
    public static func checkWith(_ options: Options, _ model: Model.Machine, _ spec: String) throws {
        let program = try read(spec)
        let seed = Model.seed(options.seed).state
        if options.cases <= 0 { throw fail("ScenarioRequiresCases") }
        for (i, (shake, (network, crash))) in schedules(BigInt(seed), options.cases).enumerated() {
            var run = options
            run.network = network
            run.crash = crash
            if case .failure(let f) = runOnce(model, program, shake, run) {
                throw fail("ScenarioFailed",
                    "\(program.title): seed \(seed) (LAWSPEC_SEED=\(seed) replays it), case \(i), shake \(shake), network \(network), crash \(crash), victim \(describe(f.report.victim)): \(f.report.reason ?? "")")
            }
        }
    }

    /// Check a scenario with the default options.
    public static func check(_ model: Model.Machine, _ spec: String) throws { try checkWith(defaults, model, spec) }
}
