// The harness plane in Swift: how often a law runs, how long it may take,
// whether its cases were adequate (cover, classify, labels), targeted search
// scores, known failures, skips and benchmarks. Statistics go to
// LAWSPEC_STATS as the same JSON records every target writes.
// ref:REQ-harness-units ref:DEC-never-pass-vacuously

import Foundation
import CryptoKit
import LawSpecRuntime

/// A JSON value, its object keys in the order they were set.
public indirect enum JSON {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case null
    case array([JSON])
    case object([(String, JSON)])

    public var text: String {
        switch self {
        case .string(let s): return Defaults.jsonText(s)
        case .number(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case .integer(let n): return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let items): return "[" + items.map { $0.text }.joined(separator: ",") + "]"
        case .object(let fields): return "{" + fields.map { Defaults.jsonText($0.0) + ":" + $0.1.text }.joined(separator: ",") + "}"
        }
    }

    /// The object with a field set (replaced in place, or added last).
    public func setting(_ key: String, _ value: JSON) -> JSON {
        guard case .object(var fields) = self else { return self }
        if let i = fields.firstIndex(where: { $0.0 == key }) { fields[i].1 = value } else { fields.append((key, value)) }
        return .object(fields)
    }

    public func removing(_ key: String) -> JSON {
        guard case .object(let fields) = self else { return self }
        return .object(fields.filter { $0.0 != key })
    }

    public subscript(key: String) -> JSON? {
        guard case .object(let fields) = self else { return nil }
        return fields.first { $0.0 == key }?.1
    }
}

extension Defaults {
    /// A JSON string literal.
    static func jsonText(_ s: String) -> String { jsonString(s) }
}

/// A value each thread sees its own of.
public final class ThreadLocal<T>: @unchecked Sendable {
    private let key = "lawspec.local." + UUID().uuidString
    private let initial: T
    public init(_ initial: T) { self.initial = initial }
    public var value: T {
        get { (Thread.current.threadDictionary[key] as? Box)?.value ?? initial }
        set { Thread.current.threadDictionary[key] = Box(newValue) }
    }
    private final class Box {
        let value: T
        init(_ value: T) { self.value = value }
    }
}

public enum Harness {
    /// What one generated case observed: cover predicates, classifications,
    /// labels and a target score.
    public struct Observation {
        let covers: [Value]
        let classes: [(String, Value)]
        let labels: [Value]
        let score: Value?
    }

    final class State: @unchecked Sendable {
        let law: String
        let test: String
        var failed = false
        var cases = 0
        var cover: [Int]
        var classes: [String: Int] = [:]
        var labels: [String: Int] = [:]
        var target = false
        var best: Value? = nil
        var aborted: (any Error)? = nil
        var extra: [(String, JSON)] = []
        let gate = NSRecursiveLock()
        init(law: String, test: String, covers: Int) {
            self.law = law
            self.test = test
            self.cover = Array(repeating: 0, count: covers)
        }
    }

    static let current = ThreadLocal<State?>(nil)

    /// Fail the harness itself (not the law): a strategy outside its input's
    /// refinement, a discard budget spent, a broken cover clause.
    public static func abort(_ code: String, _ detail: String) -> LawSpecError {
        let failure = LawSpecError(code, detail)
        if let state = current.value {
            state.gate.lock()
            if state.aborted == nil { state.aborted = failure }
            state.gate.unlock()
        }
        return failure
    }

    /// Mark a failure as the harness's, keeping the failure itself.
    public static func markHarnessFailure(_ failure: any Error) {
        if let state = current.value {
            state.gate.lock()
            if state.aborted == nil { state.aborted = failure }
            state.gate.unlock()
        }
    }

    private static func boolean(_ value: Value) throws -> Bool {
        guard case .bool(let b) = value else { throw abort("InvalidHarnessPredicate", "\(value)") }
        return b
    }

    /// Whether a score beats the best so far; a NaN never does.
    public static func higher(_ score: Value, _ best: Value?) throws -> Bool {
        switch score {
        case .float:
            if try Scalar.floatClass(score) == "nan" { return false }
            guard let other = best else { return true }
            return try Scalar.floatCompare(score, other) == 1
        case .int, .ratio, .decimal:
            guard let other = best else { return true }
            return try Scalar.compareValues(score, other) == 1
        default:
            throw abort("InvalidTargetScore", "\(score)")
        }
    }

    /// A score as the reports print it.
    public static func scoreText(_ score: Value) -> String {
        switch score {
        case .int(let n): return n.description
        case .ratio(let n, let d): return "\(n)/\(d)"
        case .decimal(let c, let e): return "\(c)e\(e)"
        case .float(let w, let b):
            switch (try? Scalar.floatClass(score)) ?? "" {
            case "nan": return "NaN"
            case "infinity": return (b >> UInt64(w - 1)) == 0 ? "Infinity" : "-Infinity"
            default: return roundTrip((try? Scalar.toDouble(score)) ?? 0)
            }
        default: return Recorded.debug(score)
        }
    }

    /// The shortest text that reads back as the same double, as .NET's "R".
    static func roundTrip(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
        return "\(d)"
    }

    private static func observe(_ state: State, _ o: Observation) throws {
        if o.covers.count != state.cover.count { throw abort("InvalidHarnessCoverObservation", "") }
        for (i, holds) in o.covers.enumerated() where try boolean(holds) { state.cover[i] += 1 }
        for (label, _) in o.classes where state.classes[label] == nil { state.classes[label] = 0 }
        var counted = Set<String>()
        for (label, holds) in o.classes where try boolean(holds) && !counted.contains(label) {
            counted.insert(label)
            state.classes[label, default: 0] += 1
        }
        var seen = Set<String>()
        for label in o.labels {
            guard case .text(let s) = label else { throw abort("InvalidHarnessLabel", "\(label)") }
            if seen.insert(s).inserted { state.labels[s, default: 0] += 1 }
        }
        if let score = o.score {
            state.target = true
            if try higher(score, state.best) { state.best = score }
        }
    }

    /// What a case observed.
    public static func observation(_ covers: [Value], _ classes: [(String, Value)], _ labels: [Value], _ score: Value?) -> Observation {
        Observation(covers: covers, classes: classes, labels: labels, score: score)
    }

    /// One generated case: count it, record what it observed, then run it. After
    /// the first failure only the law runs (shrinking does not count cases).
    public static func sample(_ observation: () throws -> Observation, _ test: () throws -> Value) throws -> Value {
        guard let state = current.value else { throw Fail.with("HarnessObservationOutsideRun") }
        state.gate.lock()
        defer { state.gate.unlock() }
        if state.failed {
            _ = try observation()
            return try test()
        }
        state.cases += 1
        do {
            try observe(state, observation())
            return try test()
        } catch {
            state.failed = true
            throw error
        }
    }

    private static func percentage(_ n: Int, _ cases: Int) -> Double {
        cases == 0 ? 0 : (10000.0 * Double(n) / Double(cases)).rounded() / 100.0
    }

    private static func statsDirectory() -> String? {
        guard let directory = ProcessInfo.processInfo.environment["LAWSPEC_STATS"], !directory.isEmpty else { return nil }
        return directory
    }

    static func hexDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    /// Write a JSON file atomically: a temporary file, then a rename.
    static func writeAtomically(_ path: String, _ text: String) {
        let temporary = path + ".\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp"
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        do {
            try text.write(toFile: temporary, atomically: false, encoding: .utf8)
            if FileManager.default.fileExists(atPath: path) { _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temporary)) }
            else { try FileManager.default.moveItem(atPath: temporary, toPath: path) }
        } catch {
            FileHandle.standardError.write(Data("LawSpec could not write \(path): \(error)\n".utf8))
        }
    }

    static func writeRecord(_ identity: String, _ record: JSON) {
        guard let directory = statsDirectory() else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        writeAtomically(URL(fileURLWithPath: directory).appendingPathComponent(hexDigest(identity) + ".json").path, record.text)
    }

    /// The expected-failure context of a `known failing` law.
    final class Expected: @unchecked Sendable {
        let law: String
        var checks: [JSON] = []
        var aborted: (any Error)? = nil
        init(law: String) { self.law = law }
    }

    static let expected = ThreadLocal<Expected?>(nil)

    private static func commit(_ record: JSON) {
        guard case .string(let law)? = record["law"] else { return }
        if let e = expected.value, e.law == law {
            e.checks.append(record)
            if case .string("harness")? = record["failureKind"], e.aborted == nil {
                e.aborted = LawSpecError("HarnessFailed", law)
            }
            return
        }
        guard case .string(let test)? = record["test"] else { return }
        writeRecord(law + "\u{0}" + test, record)
    }

    private struct CoverRow {
        let label: String
        let required: Int
        let observed: Double
        let hits: Int
        let cases: Int
        let met: Bool
    }

    private static func coverRows(_ covers: [(Int, String)], _ state: State) -> [CoverRow] {
        zip(covers, state.cover).map { cover, n in
            CoverRow(label: cover.1, required: cover.0, observed: percentage(n, state.cases), hits: n, cases: state.cases,
                     met: state.cases > 0 && 100 * n >= cover.0 * state.cases)
        }
    }

    private static func fixed(_ d: Double) -> String { String(format: "%.2f", d) }

    private static func reportText(_ state: State, _ rows: [CoverRow]) -> String {
        var text = "\(state.law): \(state.cases) generated case(s)\n"
        for row in rows {
            let shortfall = row.met ? "" : " (not met; \(row.hits)/\(row.cases) cases)"
            text += "  cover \(row.required)% \"\(row.label)\": \(fixed(row.observed))%\(shortfall)\n"
        }
        for label in state.classes.keys.sorted(by: { Scalar.compareText($0, $1) < 0 }) {
            text += "  \(label): \(fixed(percentage(state.classes[label]!, state.cases)))%\n"
        }
        for label in state.labels.keys.sorted(by: { Scalar.compareText($0, $1) < 0 }) {
            text += "  label \(label): \(fixed(percentage(state.labels[label]!, state.cases)))%\n"
        }
        if state.target, let best = state.best { text += "  best target score: " + scoreText(best) + "\n" }
        return text
    }

    private static func report(_ state: State, _ rows: [CoverRow]) -> JSON {
        let cover = JSON.array(rows.map { row in
            .object([("label", .string(row.label)), ("required", .integer(row.required)), ("observed", .number(row.observed)),
                     ("hits", .integer(row.hits)), ("cases", .integer(row.cases)), ("met", .bool(row.met))])
        })
        let classes = JSON.object(state.classes.keys.sorted { Scalar.compareText($0, $1) < 0 }.map { ($0, .integer(state.classes[$0]!)) })
        let labels = JSON.object(state.labels.keys.sorted { Scalar.compareText($0, $1) < 0 }.map { ($0, .integer(state.labels[$0]!)) })
        var o = JSON.object([("law", .string(state.law)), ("test", .string(state.test)), ("attempts", .integer(1)),
                             ("cases", .integer(state.cases)), ("cover", cover), ("classes", classes), ("labels", labels)])
        if state.target {
            o = o.setting("target", .object([("best", state.best.map { .string(scoreText($0)) } ?? .null)]))
        }
        for (k, v) in state.extra { o = o.setting(k, v) }
        return o
    }

    /// Options of a controlled run.
    public struct Options {
        let repeatCount: Int
        let retries: Int
        let timeout: Int?
        let resources: Bool
        let observed: Bool
    }

    /// A controlled run's options.
    public static func options(_ repeatCount: Int, _ retries: Int, _ timeout: Int?, _ resources: Bool, _ observed: Bool) -> Options {
        Options(repeatCount: repeatCount, retries: retries, timeout: timeout, resources: resources, observed: observed)
    }

    private static func execute(_ law: String, _ options: Options, _ test: @escaping () throws -> Void) -> (any Error)? {
        guard let ms = options.timeout else {
            do {
                try test()
                return nil
            } catch {
                return error
            }
        }
        let state = current.value
        let outcome = Locked<(any Error)??>(nil)
        let done = DispatchSemaphore(value: 0)
        let work = UncheckedBox(test)
        let carried = UncheckedBox(state)
        LawThread.start {
            current.value = carried.value
            var failure: (any Error)? = nil
            do { try work.value() } catch { failure = error }
            outcome.with { $0 = .some(failure) }
            done.signal()
        }
        if done.wait(timeout: .now() + .milliseconds(ms)) == .timedOut {
            let failure = LawSpecError("TestTimeout", "\(law) did not finish within \(ms) ms")
            markHarnessFailure(failure)
            return failure
        }
        return outcome.with { $0 } ?? nil
    }

    /// Run a test under the harness: each repeat is a complete check with its
    /// own counters, and a retry starts the repeats again. Coverage is never
    /// pooled across runs.
    public static func run(_ law: String, _ name: String, _ covers: [(Int, String)], _ options: Options, _ test: @escaping () throws -> Void) throws {
        let previous = current.value
        defer { current.value = previous }
        var history = [JSON]()
        var attempt = 1
        while true {
            var outcome: (any Error)? = nil
            var retryable = true
            var reportObject = JSON.object([])
            var repetition = 1
            while true {
                let state = State(law: law, test: name, covers: covers.count)
                current.value = state
                let failure = execute(law, options, test)
                let rows = coverRows(covers, state)
                let unmet = rows.filter { !$0.met }
                reportObject = options.observed ? report(state, rows) : .object([("law", .string(law)), ("test", .string(name))])
                let text = options.observed ? reportText(state, rows) : ""
                if options.observed { print(text, terminator: "") }
                switch (failure, state.aborted, unmet.isEmpty) {
                case (nil, let cause?, _):
                    outcome = cause
                    retryable = false
                case (nil, nil, false):
                    outcome = LawSpecError("HarnessFailed", law + ": UnmetCover\n" + text)
                    retryable = false
                case (let e?, _?, _):
                    outcome = e
                    retryable = false
                case (let e?, nil, _):
                    if options.observed && !covers.isEmpty {
                        outcome = LawSpecError("PropertyFailed", "\(e)\n" + text, cause: "\(e)")
                    } else {
                        outcome = e
                    }
                    retryable = true
                case (nil, nil, true):
                    outcome = nil
                    retryable = true
                }
                let run = reportObject.removing("law").removing("test").removing("attempts")
                    .setting("attempt", .integer(attempt)).setting("repetition", .integer(repetition))
                    .setting("outcome", .string(outcome == nil ? "passed" : "failed"))
                history.append(run)
                if outcome == nil && repetition < options.repeatCount {
                    repetition += 1
                    continue
                }
                break
            }
            if outcome != nil && retryable && attempt <= options.retries {
                attempt += 1
                continue
            }
            let status = outcome == nil ? (attempt > 1 ? "flaky" : "passed") : "failed"
            reportObject = reportObject.setting("outcome", .string(status)).setting("attempts", .integer(attempt))
            if !retryable { reportObject = reportObject.setting("failureKind", .string("harness")) }
            if options.repeatCount != 1 || options.retries != 0 {
                reportObject = reportObject.setting("repeat", .integer(options.repeatCount)).setting("runs", .array(history))
            }
            commit(reportObject)
            if let e = outcome { throw e }
            if status == "flaky" { print("\(law) is flaky: it failed, then passed on attempt \(attempt)") }
            return
        }
    }

    /// Record extra fields (a search's report) in the running test's record.
    public static func record(_ fields: [(String, JSON)]) {
        guard let state = current.value else { return }
        for (k, v) in fields {
            if let i = state.extra.firstIndex(where: { $0.0 == k }) { state.extra[i].1 = v } else { state.extra.append((k, v)) }
        }
    }

    /// A skipped law, recorded and reported.
    public static func skip(_ law: String, _ reason: String) {
        FileHandle.standardError.write(Data("SKIPPED \(law): \(reason)\n".utf8))
        commit(.object([("law", .string(law)), ("test", .string(law + " skipped")), ("outcome", .string("skipped")), ("reason", .string(reason))]))
    }

    /// A law known to fail: its checks must fail, and a law that passes fails
    /// the run so the mark is removed.
    public static func knownFailing(_ law: String, _ name: String, _ reason: String, _ checks: [() throws -> Void]) throws {
        let previous = expected.value
        let context = Expected(law: law)
        expected.value = context
        var failure: (any Error)? = nil
        do {
            for check in checks { try check() }
        } catch {
            failure = error
        }
        expected.value = previous
        func record(_ outcome: String, _ extra: [(String, JSON)]) {
            let o = JSON.object([("law", .string(law)), ("test", .string(name)), ("reason", .string(reason)), ("outcome", .string(outcome))] + extra)
            commit(o.setting("checks", .array(context.checks)))
        }
        switch (failure, context.aborted) {
        case (nil, nil):
            record("known-failing-passed", [])
            let message = "\(law) is marked known failing (\(reason)), but it passes; remove `known failing` from its harness"
            FileHandle.standardError.write(Data((message + "\n").utf8))
            throw LawSpecError("KnownFailingPassed", message)
        case (let e?, nil):
            record("known-failing", [("failure", .string("\(e)"))])
            print("\(law) is known to fail (\(reason)): \(e)")
        case (let e?, _?):
            record("failed", [("failureKind", .string("harness")), ("failure", .string("\(e)"))])
            throw e
        case (nil, let cause?):
            record("failed", [("failureKind", .string("harness"))])
            throw cause
        }
    }

    /// Measure a body: at least three iterations, about 200 ms, at most 100,000.
    public static func benchmark(_ unitName: String, _ name: String, _ body: () throws -> Void) throws {
        let clock = ContinuousClock()
        let started = clock.now
        func nanoseconds(_ d: Duration) -> Int64 { d.components.seconds * 1_000_000_000 + d.components.attoseconds / 1_000_000_000 }
        var count: Int64 = 0
        var total: Int64 = 0
        var fastest = Int64.max
        while count < 100_000 {
            let before = clock.now
            if count >= 3 && nanoseconds(before - started) >= 200_000_000 { break }
            try body()
            let elapsed = nanoseconds(clock.now - before)
            fastest = Swift.min(fastest, elapsed)
            total += elapsed
            count += 1
        }
        let mean = total / Swift.max(1, count)
        writeRecord("benchmark\u{0}" + unitName + "\u{0}" + name,
                    .object([("benchmark", .string(name)), ("unit", .string(unitName)), ("iterations", .integer(Int(count))),
                             ("mean_ns", .integer(Int(mean))), ("min_ns", .integer(Int(fastest)))]))
        print("benchmark \(name): \(count) iteration(s), mean \(fixed(Double(mean) / 1000.0)) us, fastest \(fixed(Double(fastest) / 1000.0)) us")
    }

    /// Record that a parallel unit ran.
    public static func recordParallel(_ unitName: String, _ fields: [(String, JSON)]) {
        writeRecord("parallel\u{0}" + unitName, .object([("parallel", .string(unitName))] + fields))
    }
}
