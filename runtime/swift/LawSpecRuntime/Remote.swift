// Actors and checked definitions answer the same canonical requests: a
// selector (a message name, or a definition's content hash) and its
// arguments, each in the canonical wire encoding; the reply is the result.
// ref:DEC-distribution-canonical-wire

/// One selectable remote function: its arguments' and result's descriptor
/// texts, and (on the serving side) its body over portable values.
public struct RemoteEntry: @unchecked Sendable {
    public let arguments: [String]
    public let result: String
    public let invoke: (([Value]) throws -> Value)?

    public init(_ arguments: [String], _ result: String, _ invoke: (([Value]) throws -> Value)?) {
        self.arguments = arguments
        self.result = result
        self.invoke = invoke
    }
}

/// A connection to a remote service: a node, the service's address, its
/// request kind, the signatures by selector, and the timeout in ms.
public struct RemoteClient: Sendable {
    typealias Typed = (Descriptors.Table, Descriptors.Descriptor)
    let node: Node
    let address: String
    let kind: String
    let signatures: [String: ([Typed], Typed)]
    let timeout: Int
}

public enum Remote {
    private static func fail(_ reason: String) -> LawSpecError { Fail.with("Remote", reason) }

    private static func compile(_ entry: RemoteEntry) throws -> ([RemoteClient.Typed], RemoteClient.Typed) {
        (try entry.arguments.map(Descriptors.fromText), try Descriptors.fromText(entry.result))
    }

    /// Serve a table of selectors at a name on a node ("call" for actors,
    /// "eval" for definitions); the service's address.
    @discardableResult
    public static func serve(_ node: Node, _ name: String, _ kind: String, _ table: [(String, RemoteEntry)]) throws -> String {
        if kind != "call" && kind != "eval" { throw fail("invalid_kind") }
        var compiled = [String: (([RemoteClient.Typed], RemoteClient.Typed), ([Value]) throws -> Value)]()
        for (selector, entry) in table {
            guard let invoke = entry.invoke else { throw fail("invalid_remote_function") }
            compiled[selector] = (try compile(entry), invoke)
        }
        let services = UncheckedBox(compiled)
        return try node.registerHandler(name) { frame in
            if frame.kind != kind { return (3, Array("this service does not handle that request kind".utf8)) }
            func parse() throws -> ([Value], RemoteClient.Typed, ([Value]) throws -> Value)? {
                guard case (.text(let selector), let start) = try Descriptors.decodePrefix(Wire.textType, frame.payload, 0, [:]),
                      let ((arguments, result), invoke) = services.value[selector] else { return nil }
                var at = start
                var values = [Value]()
                for (t, d) in arguments {
                    let (v, next) = try Descriptors.decodePrefix(d, frame.payload, at, t)
                    values.append(v)
                    at = next
                }
                return at == frame.payload.count ? (values, result, invoke) : nil
            }
            guard let (values, (t, d), invoke) = (try? parse()) ?? nil else {
                return (3, Array("unknown selector or malformed remote arguments".utf8))
            }
            do {
                return (0, try Descriptors.encode(d, try invoke(values), t))
            } catch let e as LawSpecError where e.code == "ActorStopped" {
                return (2, Array("the actor has stopped".utf8))
            } catch {
                return (1, Array(Node.message(error).utf8))
            }
        }
    }

    /// A client of a remote service.
    public static func connect(_ node: Node, _ address: String, _ kind: String, _ signatures: [(String, RemoteEntry)], _ timeout: Int) throws -> RemoteClient {
        if timeout < 0 { throw fail("invalid_timeout") }
        _ = try Wire.splitAddress(address)
        var compiled = [String: ([RemoteClient.Typed], RemoteClient.Typed)]()
        for (selector, entry) in signatures { compiled[selector] = try compile(entry) }
        return RemoteClient(node: node, address: address, kind: kind, signatures: compiled, timeout: timeout)
    }

    /// Call a selector with portable arguments; its portable result.
    public static func call(_ client: RemoteClient, _ selector: String, _ arguments: [Value]) throws -> Value {
        guard let (types, (resultTable, resultType)) = client.signatures[selector] else { throw fail("unknown_selector " + selector) }
        if types.count != arguments.count { throw fail("argument_count") }
        var payload = try Descriptors.encode(Wire.textType, .text(selector), [:])
        for ((t, d), v) in zip(types, arguments) { payload += try Descriptors.encode(d, v, t) }
        let (status, body) = try client.node.request(client.address, client.kind, payload, client.timeout)
        let message = String(decoding: body, as: UTF8.self)
        switch status {
        case 0: return try Descriptors.decode(resultType, body, resultTable)
        case 1: throw fail("failed " + message)
        case 2: throw fail("stopped " + message)
        case 3: throw fail("rejected " + message)
        default: throw fail("invalid_reply_status " + String(status))
        }
    }
}
