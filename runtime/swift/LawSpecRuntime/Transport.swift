// Where a node listens: an in-memory network (optionally without the secure
// layer, for tests only), or a TCP or HTTP listener on a host and port,
// advertised under a host name.
// ref:DEC-distribution-canonical-wire

/// A transport to open.
public enum Transport: @unchecked Sendable {
    case memory(network: MemoryNetwork, name: String, insecureForTests: Bool)
    case socket(kind: SocketKind, host: String, port: Int, advertise: String)
}

/// An open packet transport: its address, and sending bytes to a peer node
/// (nil, or why it failed).
protocol PacketTransport: AnyObject, Sendable {
    var address: String { get }
    func send(_ peer: String, _ bytes: [UInt8]) -> String?
    func close()
}

private final class MemoryPacketTransport: PacketTransport, @unchecked Sendable {
    let network: MemoryNetwork
    let address: String

    init(_ network: MemoryNetwork, _ address: String) {
        self.network = network
        self.address = address
    }

    func send(_ peer: String, _ bytes: [UInt8]) -> String? {
        do { return try network.send(address, peer, bytes) } catch { return "transport_closed" }
    }

    func close() { network.unregister(address) }
}

extension SocketTransport: PacketTransport {}

public enum Transports {
    /// A memory transport, registered as a name on a network.
    public static func memory(_ network: MemoryNetwork, _ name: String) -> Transport { .memory(network: network, name: name, insecureForTests: false) }

    /// A memory transport that skips the secure layer; for tests only.
    public static func insecureMemoryForTests(_ network: MemoryNetwork, _ name: String) -> Transport {
        .memory(network: network, name: name, insecureForTests: true)
    }

    public static func tcp(_ host: String, _ port: Int) -> Transport { .socket(kind: .tcp, host: host, port: port, advertise: host) }

    public static func http(_ host: String, _ port: Int) -> Transport { .socket(kind: .http, host: host, port: port, advertise: host) }

    /// A socket transport advertised under another host name.
    public static func advertise(_ transport: Transport, _ host: String) throws -> Transport {
        guard case .socket(let kind, let h, let p, _) = transport else {
            throw Fail.with("InvalidTransportOptions", "only a socket transport is advertised")
        }
        return .socket(kind: kind, host: h, port: p, advertise: host)
    }

    /// Open a transport for a receiver of each packet's source and bytes.
    static func open(_ transport: Transport, _ receive: @escaping PacketReceiver) throws -> any PacketTransport {
        switch transport {
        case .memory(let network, let name, _):
            let address = try MemoryNetwork.addressOf(name)
            if let reason = try network.register(address, receive) { throw Fail.with("TransportRegistration", reason) }
            return MemoryPacketTransport(network, address)
        case .socket(let kind, let host, let port, let advertise):
            return try SocketTransport(kind, host, port, advertise) { bytes in receive("unknown", bytes) }
        }
    }
}
