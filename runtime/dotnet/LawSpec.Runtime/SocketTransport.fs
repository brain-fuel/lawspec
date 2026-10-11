namespace LawSpec.Runtime

open System
open System.IO
open System.Net
open System.Net.Sockets
open System.Text
open System.Text.RegularExpressions
open System.Threading
open System.Threading.Tasks

/// TCP or HTTP.
type SocketKind =
    | Tcp
    | Http
    member this.Scheme = match this with Tcp -> "tcp" | Http -> "http"

/// The envelopes sockets carry: a TCP record is a 4-byte big-endian length
/// then the bytes; HTTP is one POST /lawspec per connection, answered 204,
/// with replies travelling to the peer's own listener. Parsing never needs a
/// socket, so malformed input can be checked whole and at every boundary.
/// ref:DEC-distribution-canonical-wire
module SocketProtocol =
    let private hostPattern = Regex("^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$")

    /// Whether text is an IP address or a host name.
    [<CompiledName("Host")>]
    let host (h: string) =
        not (String.IsNullOrEmpty h) && h.Length <= 253 && (fst (IPAddress.TryParse h) || hostPattern.IsMatch h)

    /// A listener's address: tcp://host:port, with IPv6 hosts in brackets.
    [<CompiledName("Address")>]
    let address (kind: SocketKind) (h: string) (port: int) =
        let name = if h.Contains ':' then "[" + h + "]" else h
        kind.Scheme + "://" + name + ":" + string port

    /// The host and port of a peer's address of the right kind.
    [<CompiledName("Endpoint")>]
    let endpoint (kind: SocketKind) (peer: string) : Result<string * int, string> =
        try
            let uri = Uri(peer)
            if uri.Scheme <> kind.Scheme || (uri.AbsolutePath <> "/" && uri.AbsolutePath <> "") || peer.EndsWith "/"
               || uri.Query <> "" || uri.UserInfo <> "" || uri.Port <= 0 || uri.Port > 65535 || uri.IsDefaultPort && not (peer.Contains(":" + string uri.Port)) then
                Error "invalid_peer_address"
            else
                let h = uri.Host.Trim('[', ']')
                if host h then Ok(h, uri.Port) else Error "invalid_peer_address"
        with _ -> Error "invalid_peer_address"

    [<CompiledName("Request")>]
    let request (peer: string) (bytes: byte[]) =
        let authority = peer.Substring("http://".Length)
        let head =
            "POST /lawspec HTTP/1.1\r\nHost: " + authority + "\r\nContent-Type: application/octet-stream\r\nContent-Length: "
            + string bytes.Length + "\r\nConnection: close\r\n\r\n"
        Array.append (Encoding.ASCII.GetBytes head) bytes

    [<CompiledName("Response")>]
    let response (code: int) =
        let reason =
            match code with
            | 204 -> "No Content"
            | 400 -> "Bad Request"
            | 404 -> "Not Found"
            | 405 -> "Method Not Allowed"
            | 411 -> "Length Required"
            | 413 -> "Content Too Large"
            | 417 -> "Expectation Failed"
            | _ -> "Request Header Fields Too Large"
        Encoding.ASCII.GetBytes("HTTP/1.1 " + string code + " " + reason + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

    /// The parse of an HTTP head so far.
    type Head =
        | More
        | Failed of int
        | Body of size: int * rest: byte[]

    let private headEnd (bytes: byte[]) =
        let mutable found = -1
        let mutable i = 0
        while found < 0 && i + 3 < bytes.Length do
            if bytes.[i] = 13uy && bytes.[i + 1] = 10uy && bytes.[i + 2] = 13uy && bytes.[i + 3] = 10uy then found <- i
            i <- i + 1
        found

    let private headers (lines: string[]) : Map<string, string> option =
        let mutable fields = Map.empty
        let mutable ok = lines.Length <= 101
        for line in lines do
            if ok then
                match line.IndexOf ':' with
                | -1 -> ok <- false
                | at ->
                    let name = line.Substring(0, at).Trim().ToLowerInvariant()
                    if name = "" || name.Contains ' ' then ok <- false
                    elif fields.ContainsKey name && (name = "content-length" || name = "transfer-encoding") then ok <- false
                    else fields <- fields.Add(name, line.Substring(at + 1).Trim())
        if ok then Some fields else None

    /// A request's head: the body size and the bytes after the head.
    [<CompiledName("Header")>]
    let header (bytes: byte[]) (maximum: int) : Head =
        match headEnd bytes with
        | -1 when bytes.Length < 16384 -> More
        | -1 -> Failed 431
        | at when at + 4 > 16384 -> Failed 431
        | at ->
            let lines = Encoding.ASCII.GetString(bytes, 0, at).Split("\r\n")
            let parts = lines.[0].Split(' ')
            let rest = bytes.[at + 4 ..]
            if parts.Length <> 3 || not (parts.[2] = "HTTP/1.1" || parts.[2] = "HTTP/1.0") then Failed 400
            elif parts.[0] <> "POST" then Failed 405
            elif parts.[1] <> "/lawspec" then Failed 404
            else
                match headers lines.[1..] with
                | None -> Failed 400
                | Some fields ->
                    if fields.ContainsKey "transfer-encoding" then Failed 400
                    elif fields.ContainsKey "expect" then Failed 417
                    else
                        match fields.TryFind "content-length" with
                        | None -> Failed 411
                        | Some v when v.Length <= 10 && v.Length > 0 && v |> Seq.forall Char.IsAsciiDigit ->
                            let size = Int64.Parse v
                            if size <= int64 maximum then Body(int size, rest) else Failed 413
                        | Some _ -> Failed 400

    /// Whether a reply head is a 204.
    [<CompiledName("Reply")>]
    let reply (bytes: byte[]) : Result<bool, string> =
        match headEnd bytes with
        | -1 when bytes.Length < 16384 -> Ok false
        | -1 -> Error "invalid_http_response"
        | at ->
            let lines = Encoding.ASCII.GetString(bytes, 0, at).Split("\r\n")
            let parts = lines.[0].Split(' ')
            if parts.Length >= 2 && parts.[0].StartsWith "HTTP/1." && parts.[1] = "204" && (headers lines.[1..]).IsSome then Ok true
            else Error "invalid_http_response"

/// An owned TCP or HTTP packet listener with per-peer writers that keep each
/// peer's order without blocking the sender. Only the security layer opens
/// these. ref:DEC-distribution-canonical-wire ref:DEC-async-native-tasks
[<Sealed>]
type SocketTransport(kind: SocketKind, host: string, port: int, advertise: string, receive: byte[] -> unit) =
    static let maxRecord = 67108864
    static let ioTimeout = 5000
    do
        if port < 0 || port > 65535 || not (SocketProtocol.host host) || not (SocketProtocol.host advertise) then
            Fail.raiseWith "InvalidTransportOptions" ""
    [<CompiledName("Ip")>]
    let ip =
        match IPAddress.TryParse host with
        | true, a -> a
        | _ ->
            let addresses = Dns.GetHostAddresses host
            match addresses |> Array.tryFind (fun a -> a.AddressFamily = AddressFamily.InterNetwork) with
            | Some a -> a
            | None -> addresses.[0]
    [<CompiledName("Listener")>]
    let listener = new TcpListener(ip, port)
    do listener.Start()
    [<CompiledName("Actual")>]
    let actual = (listener.LocalEndpoint :?> IPEndPoint).Port
    [<CompiledName("Address")>]
    let address = SocketProtocol.address kind advertise actual
    [<CompiledName("Cancel")>]
    let cancel = new CancellationTokenSource()
    [<CompiledName("Gate")>]
    let gate = obj ()
    [<CompiledName("Writers")>]
    let writers = Collections.Generic.Dictionary<string, Channels.Channel<byte[]>>()
    [<CompiledName("Workers")>]
    let workers = Collections.Concurrent.ConcurrentBag<Task>()

    [<CompiledName("Safely")>]
    let safely (action: unit -> unit) = try action () with _ -> ()

    [<CompiledName("ReadExactly")>]
    let readExactly (stream: Stream) (count: int) (token: CancellationToken) =
        task {
            let buffer = Array.zeroCreate<byte> count
            let mutable read = 0
            let mutable ok = true
            while ok && read < count do
                let! n = stream.ReadAsync(buffer, read, count - read, token)
                if n = 0 then ok <- false else read <- read + n
            return if ok then Some buffer else None
        }

    [<CompiledName("ServeTcp")>]
    let serveTcp (client: TcpClient) =
        task {
            use client = client
            use stream = client.GetStream()
            let mutable go = true
            while go && not cancel.IsCancellationRequested do
                let! prefix = readExactly stream 4 cancel.Token
                match prefix with
                | Some p ->
                    let size = (int p.[0] <<< 24) ||| (int p.[1] <<< 16) ||| (int p.[2] <<< 8) ||| int p.[3]
                    if size < 0 || size > maxRecord then go <- false
                    else
                        let! body = readExactly stream size cancel.Token
                        match body with
                        | Some b -> safely (fun () -> receive b)
                        | None -> go <- false
                | None -> go <- false
        }
        :> Task

    [<CompiledName("ReadHead")>]
    let readHead (stream: Stream) (parse: byte[] -> 'r option) (token: CancellationToken) =
        task {
            let buffer = Array.zeroCreate<byte> 4096
            let mutable acc = [||]
            let mutable result = None
            let mutable go = true
            while go do
                match parse acc with
                | Some r ->
                    result <- Some r
                    go <- false
                | None ->
                    let! n = stream.ReadAsync(buffer, 0, buffer.Length, token)
                    if n = 0 then go <- false else acc <- Array.append acc buffer.[.. n - 1]
            return result, acc
        }

    [<CompiledName("ServeHttp")>]
    let serveHttp (client: TcpClient) =
        task {
            use client = client
            use timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel.Token)
            timeout.CancelAfter ioTimeout
            use stream = client.GetStream()
            try
                let! parsed, _ =
                    readHead stream (fun bytes ->
                        match SocketProtocol.header bytes maxRecord with
                        | SocketProtocol.More -> None
                        | other -> Some other) timeout.Token
                match parsed with
                | Some(SocketProtocol.Body(size, rest)) ->
                    let! more = if rest.Length >= size then Task.FromResult(Some [||]) else readExactly stream (size - rest.Length) timeout.Token
                    match more with
                    | Some tail ->
                        let body = (Array.append rest tail).[.. size - 1]
                        safely (fun () -> receive body)
                        do! stream.WriteAsync(ReadOnlyMemory<byte>(SocketProtocol.response 204), timeout.Token)
                    | None -> do! stream.WriteAsync(ReadOnlyMemory<byte>(SocketProtocol.response 400), timeout.Token)
                | Some(SocketProtocol.Failed code) -> do! stream.WriteAsync(ReadOnlyMemory<byte>(SocketProtocol.response code), timeout.Token)
                | _ -> ()
            with _ -> ()
        }
        :> Task

    [<CompiledName("Accept")>]
    let accept =
        task {
            try
                while not cancel.IsCancellationRequested do
                    let! client = listener.AcceptTcpClientAsync(cancel.Token)
                    client.NoDelay <- true
                    workers.Add(Task.Run(fun () -> if kind = Tcp then serveTcp client else serveHttp client))
            with _ -> ()
        }

    [<CompiledName("Connect")>]
    let connect (h: string) (p: int) (token: CancellationToken) =
        task {
            let client = new TcpClient(AddressFamily.InterNetworkV6)
            client.Client.DualMode <- true
            client.NoDelay <- true
            use timeout = CancellationTokenSource.CreateLinkedTokenSource(token)
            timeout.CancelAfter ioTimeout
            do! client.ConnectAsync(h, p, timeout.Token)
            return client
        }

    [<CompiledName("WriteTcp")>]
    let writeTcp (peer: string) (h: string) (p: int) (queue: Channels.Channel<byte[]>) =
        task {
            let mutable client: TcpClient = null
            try
                let mutable go = true
                while go do
                    use idle = CancellationTokenSource.CreateLinkedTokenSource(cancel.Token)
                    idle.CancelAfter 60000
                    let! ready = (try queue.Reader.WaitToReadAsync(idle.Token).AsTask() with _ -> Task.FromResult false)
                    if not ready then go <- false
                    else
                        let mutable item = Unchecked.defaultof<byte[]>
                        while queue.Reader.TryRead(&item) do
                            let bytes = item
                            let prefix = [| byte (bytes.Length >>> 24); byte (bytes.Length >>> 16); byte (bytes.Length >>> 8); byte bytes.Length |]
                            let mutable attempts = 2
                            while attempts > 0 do
                                try
                                    if isNull client then
                                        let! c = connect h p cancel.Token
                                        client <- c
                                    let stream = client.GetStream()
                                    do! stream.WriteAsync(ReadOnlyMemory<byte>(Array.append prefix bytes), cancel.Token)
                                    attempts <- 0
                                with _ ->
                                    if not (isNull client) then client.Dispose()
                                    client <- null
                                    attempts <- attempts - 1
            finally
                if not (isNull client) then client.Dispose()
                lock gate (fun () -> writers.Remove peer |> ignore)
        }
        :> Task

    [<CompiledName("WriteHttp")>]
    let writeHttp (peer: string) (h: string) (p: int) (queue: Channels.Channel<byte[]>) =
        task {
            try
                let mutable go = true
                while go do
                    use idle = CancellationTokenSource.CreateLinkedTokenSource(cancel.Token)
                    idle.CancelAfter 60000
                    let! ready = (try queue.Reader.WaitToReadAsync(idle.Token).AsTask() with _ -> Task.FromResult false)
                    if not ready then go <- false
                    else
                        let mutable item = Unchecked.defaultof<byte[]>
                        while queue.Reader.TryRead(&item) do
                            let bytes = item
                            try
                                use! client = connect h p cancel.Token
                                use stream = client.GetStream()
                                use timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel.Token)
                                timeout.CancelAfter ioTimeout
                                do! stream.WriteAsync(ReadOnlyMemory<byte>(SocketProtocol.request peer bytes), timeout.Token)
                                let! _ =
                                    readHead stream (fun b ->
                                        match SocketProtocol.reply b with
                                        | Ok false -> None
                                        | other -> Some other) timeout.Token
                                ()
                            with _ -> ()
            finally
                lock gate (fun () -> writers.Remove peer |> ignore)
        }
        :> Task

    member _.Address = address

    /// Queue bytes for a peer; its writer connects and sends in order.
    member _.Send(peer: string, bytes: byte[]) : Result<unit, string> =
        if bytes.Length > maxRecord then Error "record_too_large"
        else
            match SocketProtocol.endpoint kind peer with
            | Error e -> Error e
            | Ok(h, p) ->
                lock gate (fun () ->
                    match writers.TryGetValue peer with
                    | true, queue ->
                        if queue.Writer.TryWrite bytes then Ok() else Error "transport_queue_full"
                    | _ when writers.Count >= 512 -> Error "transport_busy"
                    | _ ->
                        let queue = Channels.Channel.CreateBounded<byte[]>(1024)
                        writers.[peer] <- queue
                        queue.Writer.TryWrite bytes |> ignore
                        workers.Add(Task.Run(fun () -> if kind = Tcp then writeTcp peer h p queue else writeHttp peer h p queue))
                        Ok())

    member _.Close() =
        cancel.Cancel()
        (try listener.Stop() with _ -> ())
        (try Task.WaitAll(Array.ofSeq workers, 5000) |> ignore with _ -> ())

    interface IDisposable with
        member this.Dispose() = this.Close()
