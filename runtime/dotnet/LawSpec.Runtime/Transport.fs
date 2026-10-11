namespace LawSpec.Runtime

open System

/// Where a node listens: an in-memory network (optionally without the secure
/// layer, for tests only), or a TCP or HTTP listener on a host and port,
/// advertised under a host name.
/// ref:DEC-distribution-canonical-wire
type Transport =
    | Memory of network: MemoryNetwork * name: string * insecureForTests: bool
    | Socket of kind: SocketKind * host: string * port: int * advertise: string

/// An open packet transport: its address, and sending bytes to a peer node.
type IPacketTransport =
    inherit IDisposable
    abstract Address: string
    abstract Send: peer: string * bytes: byte[] -> Result<unit, string>

/// Opening transports for a receiver of each packet's bytes (and its source,
/// when the transport knows it).
module Transports =
    /// A memory transport, registered as a name on a network.
    [<CompiledName("Memory")>]
    let memory (network: MemoryNetwork) (name: string) = Memory(network, name, false)

    /// A memory transport that skips the secure layer; for tests only.
    [<CompiledName("InsecureMemoryForTests")>]
    let insecureMemoryForTests (network: MemoryNetwork) (name: string) = Memory(network, name, true)

    [<CompiledName("Tcp")>]
    let tcp (host: string) (port: int) = Socket(Tcp, host, port, host)

    [<CompiledName("Http")>]
    let http (host: string) (port: int) = Socket(Http, host, port, host)

    /// A socket transport advertised under another host name.
    [<CompiledName("Advertise")>]
    let advertise (transport: Transport) (host: string) =
        match transport with
        | Socket(kind, h, p, _) -> Socket(kind, h, p, host)
        | Memory _ -> Fail.raiseWith "InvalidTransportOptions" "only a socket transport is advertised"

    /// Open a transport.
    let open' (transport: Transport) (receive: string -> byte[] -> unit) : IPacketTransport =
        match transport with
        | Memory(network, name, _) ->
            let address = MemoryNetwork.AddressOf name
            match network.Register(address, receive) with
            | Error reason -> Fail.raiseWith "TransportRegistration" reason
            | Ok() ->
                { new IPacketTransport with
                    member _.Address = address
                    member _.Send(peer, bytes) =
                        try network.Send(address, peer, bytes) with _ -> Error "transport_closed"
                    member _.Dispose() = network.Unregister address }
        | Socket(kind, host, port, advertise) ->
            let socket = new SocketTransport(kind, host, port, advertise, receive "unknown")
            { new IPacketTransport with
                member _.Address = socket.Address
                member _.Send(peer, bytes) = socket.Send(peer, bytes)
                member _.Dispose() = socket.Close() }
