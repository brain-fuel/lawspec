// User-owned LawSpec adapter: the wire encoding, and nodes talking over
// in-memory, TCP and HTTP transports. ref:DEC-acceptance-with-mutants
import Foundation
import LawSpecRuntime

extension Example.Distribution {
    static func encoded(_ text: String, _ seed: UInt64, _ size: Int32, _ count: Int32) -> PersistentList<String> {
        PersistentList(try! Network.wireEncoded(text, BigInt(seed), Int(size), Int(count)))
    }

    static func roundTrips(_ text: String, _ seed: UInt64, _ size: Int32, _ count: Int32) -> Bool {
        try! Network.wireRoundTrips(text, BigInt(seed), Int(size), Int(count))
    }

    private static func memory(_ seed: Int32, _ loss: Double, _ duplicate: Double, _ delay: Double, _ record: Bool) throws -> MemoryNetwork {
        try Network.memory(Network.memoryOptions(BigInt(Int(seed) & 0xFFFF), loss, duplicate, delay, record))
    }

    private static func node(_ transport: Transport) throws -> Node { try Network.openNode(transport, Network.options()) }

    private static func local() throws -> Node { try node(Network.tcp("127.0.0.1", 0)) }

    /// Run a body on a thread of its own; the function joins it.
    private static func spawn(_ body: @escaping @Sendable () throws -> Void) -> () throws -> Void {
        let outcome = Locked<Result<Void, any Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        LawThread.start {
            let result = Result { try body() }
            outcome.with { $0 = result }
            done.signal()
        }
        return {
            done.wait()
            try outcome.with { $0 }!.get()
        }
    }

    static func remoteShifted(_ x: Int32) async -> Int64 {
        try! await LawThread.run {
            let network = try memory(x, 0.2, 0.2, 0, false)
            defer { network.close() }
            let here = try node(Network.memoryTransport(network, "here"))
            defer { here.close() }
            let there = try node(Network.memoryTransport(network, "there"))
            defer { there.close() }
            try LawSpec.RemoteDefinitions.serve(there)
            guard case .int(let n) = try LawSpec.RemoteDefinitions.evaluate(here, there.address, "example.distribution::shifted", [.int(BigInt(x))]),
                  let shifted = n.exactly(Int64.self) else { fatalError("unexpected result") }
            return shifted
        }
    }

    static func openTally() -> Tally { Tally(count: 0) }

    static func add(_ tally: Tally, _ n: UInt8) -> Pair<Int64, Tally> {
        let after = tally.count + Int64(n)
        return Pair(first: after, second: Tally(count: after))
    }

    private static let tallyHandlers = LawSpec.Actors.TallyActorHandlers(openTally: openTally, add: add)

    static func remoteAdds(_ n: UInt8) async -> Int64 {
        try! await LawThread.run {
            let server = try local()
            defer { server.close() }
            let client = try local()
            defer { client.close() }
            let actor = try LawSpec.Actors.TallyActor.start(tallyHandlers)
            defer { actor.stop() }
            let address = try actor.serve(server, "tally")
            let tally = try LawSpec.Actors.TallyActor.connect(client, address)
            try tally.add(n)
            return try tally.add(n)
        }
    }

    static func remoteDoubling(_ x: Int32) async -> Int64 {
        try! await LawThread.run {
            let server = try node(Network.http("127.0.0.1", 0))
            defer { server.close() }
            let client = try node(Network.http("127.0.0.1", 0))
            defer { client.close() }
            let first = try LawSpec.Sessions.Doubling.listen(server, "doubling")
            let second = try LawSpec.Sessions.Doubling.dial(client, server.address + "/doubling")
            let worker = spawn {
                let (got, next) = try second.receive()
                try next.send(2 * Int64(got))
            }
            let (reply, _) = try first.send(x).receive()
            try worker()
            return reply
        }
    }

    static func remoteLedger(_ x: Int32) async -> Int64 {
        try! await LawThread.run {
            let here = try local()
            defer { here.close() }
            let there = try local()
            defer { there.close() }
            let ledger = try LawSpec.Mailboxes.LedgerMailbox.serve(there, "ledger")
            let sender = try LawSpec.Mailboxes.LedgerMailbox.connect(here, there.address + "/ledger")
            try sender.send(Int64(x))
            try sender.send(Int64(x))
            let total = try ledger.receive(timeout: 5) + ledger.receive(timeout: 5)
            // Nothing more comes, so receiving within a moment gives nothing.
            return try ledger.receiveWithin(0.02) != nil ? -1 : total
        }
    }

    static func remoteHandoff(_ x: Int32) async -> Int64 {
        try! await LawThread.run {
            let here = try local()
            defer { here.close() }
            let there = try local()
            defer { there.close() }
            // A local conversation on this node; its first end goes to the other.
            let (first, second) = LawSpec.Sessions.Doubling.channel()
            let worker = spawn {
                let (got, next) = try second.receive()
                try next.send(2 * Int64(got))
            }
            let giving = try LawSpec.Sessions.Handoff.listen(here, "handoff")
            let taking = try LawSpec.Sessions.Handoff.dial(there, here.address + "/handoff")
            try giving.send(first)
            let (moved, _) = try taking.receive()
            let (reply, _) = try moved.send(x).receive()
            try worker()
            return reply
        }
    }

    static func remoteHandoffOnward(_ x: Int32) async -> Int64 {
        try! await LawThread.run {
            let network = try memory(x, 0.1, 0.1, 0.005, false)
            defer { network.close() }
            let a = try node(Network.memoryTransport(network, "a"))
            let b = try node(Network.memoryTransport(network, "b"))
            defer {
                a.close()
                b.close()
            }
            let c = try node(Network.memoryTransport(network, "c"))
            defer { c.close() }
            let d = try node(Network.memoryTransport(network, "d"))
            defer { d.close() }
            // A conversation between A and C, which sends at once; A's end
            // moves to B, then to D, and answers from there.
            let first = try LawSpec.Sessions.Answering.listen(a, "answering")
            let second = try LawSpec.Sessions.Answering.dial(c, a.address + "/answering").send(x)
            let toB = try LawSpec.Sessions.Passing.listen(a, "to-b")
            let atB = try LawSpec.Sessions.Passing.dial(b, a.address + "/to-b")
            try toB.send(first)
            let (moved, _) = try atB.receive()
            let toD = try LawSpec.Sessions.Passing.listen(b, "to-d")
            let atD = try LawSpec.Sessions.Passing.dial(d, b.address + "/to-d")
            try toD.send(moved)
            let (answering, _) = try atD.receive()
            // The end no longer needs A or B.
            a.close()
            b.close()
            let (got, next) = try answering.receive()
            try next.send(2 * Int64(got))
            return try second.receive().0
        }
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        return (0...(haystack.count - needle.count)).contains { haystack[$0..<($0 + needle.count)].elementsEqual(needle) }
    }

    // A definition evaluated on another node: its request names the
    // definition's content hash, which shows on the wire only in the clear.
    static func sealedOnTheWire(_ x: Int32) async -> Bool {
        try! await LawThread.run {
            let name = "example.distribution::shifted"
            let digest = Array(try LawSpec.RemoteDefinitions.digest(name).utf8)
            var seen = [Bool?]()
            for insecure in [false, true] {
                let network = try memory(x, 0, 0, 0, true)
                defer { network.close() }
                let transport = insecure ? Network.insecureMemoryTransportForTests : Network.memoryTransport
                let here = try node(transport(network, "here"))
                defer { here.close() }
                let there = try node(transport(network, "there"))
                defer { there.close() }
                try LawSpec.RemoteDefinitions.serve(there)
                if case .int(let n) = try LawSpec.RemoteDefinitions.evaluate(here, there.address, name, [.int(BigInt(x))]), n == BigInt(Int64(x) + 1000) {
                    seen.append(Network.recorded(network).contains { contains($0, digest) })
                } else {
                    seen.append(nil)
                }
            }
            return seen == [false, true]
        }
    }

    static func handshakeAgrees(_ text: String) -> Bool {
        let f = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 13 else { return false }
        return Network.handshakeVector(f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12])
    }
}
