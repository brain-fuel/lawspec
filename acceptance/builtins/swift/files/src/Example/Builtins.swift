// User-owned LawSpec adapter: native code that gets the built-in abilities'
// handlers as arguments. ref:DEC-acceptance-with-mutants
import Foundation
import LawSpecRuntime

extension Example.Builtins {
    static func elapsed(_ clock: any LawSpec.Abilities.LawspecTime.Clock, _ count: Int32) -> Duration {
        let start = clock.now().value
        for _ in 0..<max(0, count) { _ = clock.now() }
        return .microseconds(clock.now().value - start)
    }

    static func token(_ secureRandom: any LawSpec.Abilities.LawspecRandomness.SecureRandom, _ count: Int32) -> [UInt8] {
        secureRandom.secureBytes(count)
    }

    static func listening(_ ports: any LawSpec.Abilities.LawspecHost.Ports, _ value0: Int32) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        if socket < 0 { return false }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(ports.freePort()).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return bound == 0 && listen(socket, 1) == 0
    }

    static func charge(_ log: any LawSpec.Abilities.LawspecLogging.Log, _ cents: Int32) -> Bool {
        if cents % 2 == 0 {
            log.logMessage(.info, "charged \(cents)")
            return true
        }
        return false
    }
}
