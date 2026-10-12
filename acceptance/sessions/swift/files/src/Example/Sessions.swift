// User-owned LawSpec adapter: adding through a server thread, over the typed
// channel ends generated from the Serve and Hire protocols.
// ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.Sessions {
    // The server: receive two numbers, send their sum.
    private static func serve(_ server: LawSpec.Sessions.Serve.First.ReceiveInt32Step1) throws {
        let (a, afterA) = try server.receive()
        let (b, afterB) = try afterA.receive()
        try afterB.send(Int64(a) + Int64(b))
    }

    // The client: send both numbers, receive the sum.
    private static func ask(_ client: LawSpec.Sessions.Serve.Second.SendInt32Step1, _ a: Int32, _ b: Int32) throws -> Int64 {
        let afterA = try client.send(a)
        let afterB = try afterA.send(b)
        return try afterB.receive().0
    }

    static func add(_ value0: Int32, _ value1: Int32) async -> BigInt {
        let (first, second) = LawSpec.Sessions.Serve.channel()
        async let server: Void = LawThread.run { try serve(first) }
        let sum = try! await LawThread.run { try ask(second, value0, value1) }
        try! await server
        return BigInt(sum)
    }

    // A manager is handed the server's end over a Hire channel and serves it.
    static func addHired(_ value0: Int32, _ value1: Int32) async -> BigInt {
        let (serverEnd, clientEnd) = LawSpec.Sessions.Serve.channel()
        let (hiring, hired) = LawSpec.Sessions.Hire.channel()
        async let manager: Void = LawThread.run { try serve(try hired.receive().0) }
        let sum = try! await LawThread.run {
            try hiring.send(serverEnd)
            return try ask(clientEnd, value0, value1)
        }
        try! await manager
        return BigInt(sum)
    }
}
