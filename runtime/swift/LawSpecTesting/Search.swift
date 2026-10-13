// LawSpec's descriptor search, apart from generation and shrinking: the
// portable seeded climb of a `target` (ten starting points, sixty rounds, at
// most twenty-four moves a round and four hundred checks), and the failure
// database that keeps a failing law's inputs (LAWSPEC_FAILURES) and replays
// them first on the next run. ref:REQ-harness-units
// ref:DEC-portable-seeded-generation ref:DEC-shrink-within-domain

import Foundation
import LawSpecRuntime

public enum Search {
    private static func inputFile(_ law: String) -> String? {
        guard let directory = ProcessInfo.processInfo.environment["LAWSPEC_FAILURES"], !directory.isEmpty else { return nil }
        let name = Harness.hexDigest(law).lowercased()
        return URL(fileURLWithPath: directory).appendingPathComponent("inputs").appendingPathComponent(name + ".json").path
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func unhex(_ text: String) -> [UInt8]? {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(decoding: chars[i..<(i + 2)], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(b)
            i += 2
        }
        return bytes
    }

    /// Keep a failing case's inputs, encoded on the canonical wire.
    public static func remember(_ law: String, _ descriptors: [String], _ values: [Value]) throws {
        guard let file = inputFile(law) else { return }
        let inputs = try zip(descriptors, values).map { descriptor, value -> JSON in
            let (table, d) = try Descriptors.fromText(descriptor)
            return .string(hex(try Descriptors.encode(d, value, table)))
        }
        let record = JSON.object([("law", .string(law)), ("inputs", .array(inputs))])
        try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        Harness.writeAtomically(file, record.text)
    }

    private static func keep(_ law: String, _ descriptors: [String], _ values: [Value]) {
        do { try remember(law, descriptors, values) } catch {
            FileHandle.standardError.write(Data("LawSpec could not save inputs for \(law): \(error)\n".utf8))
        }
    }

    /// Run a case, keeping its inputs when it fails.
    public static func guardCase(_ law: String, _ descriptors: [String], _ values: [Value], _ check: () throws -> Value) throws -> Value {
        do {
            let result = try check()
            if case .bool(false) = result { keep(law, descriptors, values) }
            return result
        } catch {
            keep(law, descriptors, values)
            throw error
        }
    }

    /// Replay the kept failing inputs of a law, if any, before its generated
    /// cases; a repaired or obsolete one is removed.
    public static func replay(_ law: String, _ descriptors: [String], _ check: ([Value]) throws -> Value?) throws {
        guard let file = inputFile(law), FileManager.default.fileExists(atPath: file) else { return }
        var values: [Value]? = nil
        if let data = FileManager.default.contents(atPath: file),
           let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           record["law"] as? String == law, let inputs = record["inputs"] as? [String], inputs.count == descriptors.count {
            values = try? zip(descriptors, inputs).map { descriptor, text -> Value in
                let (table, d) = try Descriptors.fromText(descriptor)
                guard let bytes = unhex(text) else { throw Fail.with("InvalidSavedInputs") }
                return try Descriptors.decode(d, bytes, table)
            }
        }
        if let values {
            FileHandle.standardError.write(Data("\(law): replaying the failing inputs kept in .lawspec/failures\n".utf8))
            if case .bool(false)? = try check(values) { throw Fail.with("ReplayFailed", law) }
        } else {
            FileHandle.standardError.write(Data("\(law): discarding incompatible saved inputs\n".utf8))
        }
        try? FileManager.default.removeItem(atPath: file)
    }

    private static func bounds(_ d: Descriptors.Descriptor) -> (BigInt, BigInt) {
        guard case .forms(let parts) = d, parts.count == 4 else { return (.zero, .zero) }
        func number(_ x: Descriptors.Descriptor) -> BigInt? { if case .number(let n) = x { return n } else { return nil } }
        return Descriptors.generationBounds(number(parts[2]), number(parts[3]))
    }

    /// Each move changes one integer leaf, within its wire bounds.
    private static func moves(_ d: Descriptors.Descriptor, _ value: Value, _ table: Descriptors.Table) throws -> [Value] {
        let resolved = try Descriptors.resolve(d, table)
        guard case .forms(let parts) = resolved, case .atom(let head)? = parts.first else { return [] }
        switch (head, value) {
        case ("int", .int(let n)) where parts.count == 4:
            let (lo, hi) = bounds(resolved)
            var result = [BigInt]()
            for x in [n + .one, n - .one, n * 2, n / 2, n + (hi - n) / 2, n - (n - lo) / 2]
            where x != n && x >= lo && x <= hi && !result.contains(x) { result.append(x) }
            return result.map { .int($0) }
        case ("list", .list(let items)) where parts.count == 2:
            return try fieldMoves(items.map { _ in parts[1] }, items, table).map { .list($0) }
        case ("maybe", .data("Maybe::Just", let f)) where parts.count == 2 && f.count == 1:
            return try moves(parts[1], f[0], table).map { .data("Maybe::Just", [$0]) }
        case ("either", .data(let tag, let f)) where parts.count == 3 && f.count == 1:
            return try moves(tag == "Either::Left" ? parts[1] : parts[2], f[0], table).map { .data(tag, [$0]) }
        case ("data", .data(let tag, let values)) where parts.count >= 2:
            for c in parts.dropFirst(2) {
                if case .forms(let cparts) = c, cparts.count >= 2, case .atom("ctor") = cparts[0] {
                    var name = ""
                    if case .quoted(let s) = cparts[1] { name = s }
                    if case .atom(let s) = cparts[1] { name = s }
                    if name == tag { return try fieldMoves(Array(cparts.dropFirst(2)), values, table).map { .data(tag, $0) } }
                }
            }
            throw Fail.with("ForeignWireConstructor", tag)
        default:
            return []
        }
    }

    private static func fieldMoves(_ ds: [Descriptors.Descriptor], _ values: [Value], _ table: Descriptors.Table) throws -> [[Value]] {
        guard let d = ds.first, let v = values.first else { return [] }
        let rest = Array(values.dropFirst())
        return try moves(d, v, table).map { [$0] + rest } + (try fieldMoves(Array(ds.dropFirst()), rest, table)).map { [v] + $0 }
    }

    private static func inputMoves(_ tables: [(Descriptors.Table, Descriptors.Descriptor)], _ values: [Value]) throws -> [[Value]] {
        guard let (table, d) = tables.first, let v = values.first else { return [] }
        let rest = Array(values.dropFirst())
        return try moves(d, v, table).map { [$0] + rest } + (try inputMoves(Array(tables.dropFirst()), rest)).map { [v] + $0 }
    }

    private struct Climb {
        var tried = 0
        var accepted = 0
        var best: Value? = nil
        var values: [Value]? = nil
    }

    private struct SearchFailed: Error {
        let error: any Error
        let state: Climb
        let values: [Value]
    }

    /// Climb towards the highest score of a law's `target`, from the run's seed.
    /// The check gives nil for inputs outside the law's domain, or the score.
    public static func climb(_ law: String, _ descriptors: [String], _ check: ([Value]) throws -> Value?) throws {
        let text = ProcessInfo.processInfo.environment["LAWSPEC_SEED"] ?? ""
        let seed = text.isEmpty ? BigInt.zero : (BigInt(text) ?? .zero)
        let tables = try descriptors.map(Descriptors.fromText)
        func generate(_ s: BigInt) throws -> [Value] {
            var state = Random.seed(s)
            return try tables.map { table, d in
                let (v, next) = try Descriptors.generate(d, table, state, 8)
                state = next
                return v
            }
        }
        func attempt(_ values: [Value], _ state: Climb) throws -> (Bool, Climb) {
            if state.tried >= 400 { return (false, state) }
            var next = state
            next.tried += 1
            let score: Value?
            do { score = try check(values) } catch { throw SearchFailed(error: error, state: next, values: values) }
            guard let s = score else { return (false, next) }
            next.accepted += 1
            if try Harness.higher(s, state.best) {
                next.best = s
                next.values = values
                return (true, next)
            }
            return (false, next)
        }
        func publish(_ outcome: String, _ state: Climb) {
            let best = state.best.map(Harness.scoreText)
            print("\(law): targeted search tried \(state.tried) case(s)" + (best.map { "; best score " + $0 } ?? ""))
            let search = JSON.object([("seed", .string(seed.description)), ("tried", .integer(state.tried)),
                                      ("accepted", .integer(state.accepted)), ("best", best.map { .string($0) } ?? .null)])
            Harness.record([("search", search), ("outcome", .string(outcome))])
        }
        do {
            var state = Climb()
            for k in 0..<10 { state = try attempt(try generate(seed + BigInt(k)), state).1 }
            var step = 0
            while step < 60 && state.tried < 400 {
                let candidates = try state.values.map { Array(try inputMoves(tables, $0).prefix(24)) } ?? []
                var rose = false
                for candidate in candidates {
                    let (rising, next) = try attempt(candidate, state)
                    rose = rose || rising
                    state = next
                }
                if !rose { state = try attempt(try generate(seed + BigInt(1000) + BigInt(step)), state).1 }
                step += 1
            }
            publish("passed", state)
        } catch let failed as SearchFailed {
            keep(law, descriptors, failed.values)
            publish("failed", failed.state)
            let inputs = (try? zip(tables, failed.values).map { pair, v in hex(try Descriptors.encode(pair.1, v, pair.0)).uppercased() }) ?? []
            throw LawSpecError("TargetFailed", "\(law) (seed \(seed), inputs \(inputs.joined(separator: ", "))): \(failed.error)", cause: "\(failed.error)")
        }
    }
}
