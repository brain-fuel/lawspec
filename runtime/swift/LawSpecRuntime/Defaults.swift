// The default handlers of the built-in abilities in Swift: the real clock,
// the run's seeded random sequence and the system's secure random source,
// files, environment variables and ports, logging, and pausing. Values are
// portable; the generated protocols convert them where native code meets
// them. ref:DEC-typed-core-boundary ref:DEC-swift-runtime-from-scratch

import Foundation

public enum Defaults {
    private static func fail(_ code: String, _ detail: String = "") -> LawSpecError { Fail.with(code, detail) }

    private static func just(_ v: Value) -> Value { .data("Maybe::Present", [v]) }
    private static let nothing = Value.data("Maybe::Absent", [])

    // The wall clock at start, then the monotonic clock: a later clock
    // correction never moves time backwards.
    private static let origin = Int64(Date().timeIntervalSince1970 * 1000) * 1000
    private static let started = ContinuousClock.now

    /// Microseconds since the Unix epoch, never decreasing.
    public static func nowMicros() -> Int64 {
        let elapsed = ContinuousClock.now - started
        let (seconds, attoseconds) = elapsed.components
        return origin + seconds * 1_000_000 + attoseconds / 1_000_000_000_000
    }

    /// Sleep at least a number of microseconds.
    public static func sleepMicros(_ micros: Int64) {
        let deadline = ContinuousClock.now + .microseconds(micros)
        while ContinuousClock.now < deadline {
            let left = deadline - ContinuousClock.now
            let (seconds, attoseconds) = left.components
            Thread.sleep(forTimeInterval: Swift.max(0.001, Double(seconds) + Double(attoseconds) / 1e18))
        }
    }

    private static func integer(_ v: Value) throws -> BigInt {
        guard case .int(let n) = v else { throw fail("IntegerRequired", "\(v)") }
        return n
    }

    private static func text(_ v: Value) throws -> String {
        guard case .text(let s) = v else { throw fail("TextRequired", "\(v)") }
        return s
    }

    private static let mask = (BigInt.one << 64) - .one

    private static func randomStep(_ s: BigInt) -> BigInt {
        (BigInt(6364136223846793005) * s + BigInt(1442695040888963407)) & mask
    }

    private static func secureBelow(_ bound: Int64) -> Int64 {
        if bound < 1 { return 0 }
        var generator = SystemRandomNumberGenerator()
        return Int64.random(in: 0..<bound, using: &generator)
    }

    private static func secureBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Swift.max(0, count)).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func temporaryRoot() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let candidates = ["TMPDIR", "TMP", "TEMP"].compactMap { environment[$0] }.filter { !$0.isEmpty } + [NSTemporaryDirectory()]
        var isDirectory: ObjCBool = false
        for root in candidates where FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) && isDirectory.boolValue {
            return URL(fileURLWithPath: root).standardizedFileURL.path
        }
        throw fail("NoTemporaryDirectory")
    }

    private static func temporary(_ directory: Bool, _ prefix: String) throws -> String {
        if prefix.contains("\0") || prefix.contains("/") || prefix.contains("\\") { throw fail("InvalidTemporaryPrefix", prefix) }
        let manager = FileManager.default
        for _ in 0..<100 {
            let path = URL(fileURLWithPath: try temporaryRoot()).appendingPathComponent(prefix + hex(secureBytes(16))).path
            if manager.fileExists(atPath: path) { continue }
            if directory {
                try? manager.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } else {
                _ = manager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            return path
        }
        throw fail("TemporaryNameExhausted", prefix)
    }

    private static func validName(_ name: String) -> Bool { !name.isEmpty && !name.contains("\0") && !name.contains("=") }

    private static func restoreEnvironment(_ saved: String) throws {
        guard let data = saved.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              decoded.allSatisfy({ validName($0.key) && !$0.value.contains("\0") }) else {
            throw fail("InvalidEnvironmentSnapshot")
        }
        for name in ProcessInfo.processInfo.environment.keys where decoded[name] == nil { unsetenv(name) }
        for (name, value) in decoded { setenv(name, value, 1) }
    }

    /// A crypto ability's default handler, set by Crypto when a program uses
    /// lawspec.crypto.
    public static let cryptoHandler = Locked<@Sendable (String) throws -> Effects.Handler>({ key in
        throw Fail.with("UnknownDefaultHandler", key)
    })

    /// The clause name that marks the default (real) Clock handler.
    public static let realClockMarker = "lawspec.realClock"

    /// The default handler of a built-in ability, by its key.
    public static func handler(_ key: String) throws -> Effects.Handler {
        if key.hasPrefix("lawspec.crypto::ability::") { return try cryptoHandler.with { $0 }(key) }
        switch key {
        case "lawspec.time::ability::Clock":
            return Effects.stateless([
                // Marks the real clock, so a workflow knows its time is real.
                (realClockMarker, { @Sendable _, _ in .unit }),
                ("now", { _, _ in .data("lawspec.time::type::Instant::Instant", [.int(BigInt(nowMicros()))]) }),
                ("sleep", { _, args in
                    guard case .data(_, let f)? = args.first, case .int(let micros)? = f.first, let n = micros.exactly(Int64.self) else {
                        throw fail("InvalidDuration")
                    }
                    sleepMicros(n)
                    return .unit
                }),
            ])
        case "lawspec.randomness::ability::Random":
            let text = ProcessInfo.processInfo.environment["LAWSPEC_SEED"] ?? ""
            let seed = BigInt(text) ?? .zero
            let cell = Effects.Cell(.int(seed & mask))
            return Effects.stateless([
                ("randomBelow", { _, args in
                    let bound = try integer(args[0])
                    return try cell.update { state in
                        let first = randomStep(try integer(state))
                        let second = randomStep(first)
                        let bits = ((first >> 32) << 32) | (second >> 32)
                        let draw = bound.signum > 0 ? bits % bound : .zero
                        return (.int(draw), .int(second))
                    }
                }),
            ])
        case "lawspec.randomness::ability::SecureRandom":
            return Effects.stateless([
                ("secureBytes", { _, args in .bytes(secureBytes(try integer(args[0]).exactly(Int.self) ?? 0)) }),
                ("secureBelow", { _, args in .int(BigInt(secureBelow(try integer(args[0]).exactly(Int64.self) ?? Int64.max))) }),
                ("secureToken", { _, _ in .text(hex(secureBytes(32))) }),
            ])
        case "lawspec.host::ability::FileSystem":
            return Effects.stateless([
                ("readBytes", { _, args in
                    let p = try text(args[0])
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: p, isDirectory: &isDirectory), !isDirectory.boolValue,
                          let data = FileManager.default.contents(atPath: p) else { return nothing }
                    return just(.bytes([UInt8](data)))
                }),
                ("writeBytes", { _, args in
                    guard args.count == 2, case .text(let p) = args[0], case .bytes(let b) = args[1] else { throw fail("InvalidArguments", "writeBytes") }
                    do { try Data(b).write(to: URL(fileURLWithPath: p)) } catch { throw fail("WriteFailed", "\(p): \(error)") }
                    return .unit
                }),
                ("pathExists", { _, args in .bool(FileManager.default.fileExists(atPath: try text(args[0]))) }),
                ("removePath", { _, args in
                    let p = try text(args[0])
                    if FileManager.default.fileExists(atPath: p) { try? FileManager.default.removeItem(atPath: p) }
                    return .unit
                }),
                ("temporaryDirectory", { _, args in .text(try temporary(true, try text(args[0]))) }),
                ("temporaryFile", { _, args in .text(try temporary(false, try text(args[0]))) }),
            ])
        case "lawspec.host::ability::Environment":
            return Effects.stateless([
                ("environmentVariable", { _, args in
                    let name = try text(args[0])
                    guard validName(name), let value = getenv(name) else { return nothing }
                    return just(.text(String(cString: value)))
                }),
                ("environmentSnapshot", { _, _ in
                    let all = ProcessInfo.processInfo.environment
                    let keys = all.keys.sorted { Scalar.compareText($0, $1) < 0 }
                    let body = keys.map { jsonString($0) + ":" + jsonString(all[$0]!) }.joined(separator: ",")
                    return .text("{" + body + "}")
                }),
                ("restoreEnvironment", { _, args in
                    try restoreEnvironment(try text(args[0]))
                    return .unit
                }),
            ])
        case "lawspec.host::ability::Ports":
            return Effects.stateless([("freePort", { _, _ in .int(BigInt(try freePort())) })])
        case "lawspec.logging::ability::Log":
            return Effects.stateless([
                ("logMessage", { _, args in
                    guard args.count == 2, case .data(let level, _) = args[0], case .text(let message) = args[1] else {
                        throw fail("InvalidArguments", "logMessage")
                    }
                    let name = Recorded.lastPart(level)
                    let line = "[\(name.lowercased())] \(message)"
                    if name == "Warning" || name == "Error" {
                        FileHandle.standardError.write(Data((line + "\n").utf8))
                    } else {
                        print(line)
                    }
                    return .unit
                }),
            ])
        case "lawspec.logging::ability::Trace":
            return Effects.stateless([
                ("traceEvent", { _, args in
                    FileHandle.standardError.write(Data(("lawspec: " + (try text(args[0])) + "\n").utf8))
                    return .unit
                }),
            ])
        case "lawspec.concurrent::ability::Async":
            return Effects.stateless([
                ("pause", { _, _ in
                    sched_yield()
                    return .unit
                }),
            ])
        default:
            throw fail("UnknownDefaultHandler", key)
        }
    }

    /// A free TCP port on the loopback interface.
    public static func freePort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        if socket < 0 { throw fail("NoFreePort") }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) }
        }
        if bound != 0 { throw fail("NoFreePort") }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        if named != 0 { throw fail("NoFreePort") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// A JSON string literal.
    public static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}
