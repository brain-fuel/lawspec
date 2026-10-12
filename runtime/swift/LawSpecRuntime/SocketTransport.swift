// TCP and HTTP packet transports over POSIX sockets. A TCP record is a
// 4-byte big-endian length then the bytes; HTTP is one POST /lawspec per
// connection, answered 204, with replies travelling to the peer's own
// listener. Parsing never needs a socket, so malformed input can be checked
// whole and at every boundary.
// ref:DEC-distribution-canonical-wire

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// TCP or HTTP.
public enum SocketKind: Sendable {
    case tcp
    case http

    public var scheme: String { self == .tcp ? "tcp" : "http" }
}

public enum SocketProtocol {
    private static func isIp(_ h: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, h, &v4) == 1 || inet_pton(AF_INET6, h, &v6) == 1
    }

    private static func isHostName(_ h: String) -> Bool {
        let chars = Array(h.utf8)
        func alnum(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
        guard let first = chars.first, let last = chars.last, alnum(first), alnum(last) else { return false }
        return chars.allSatisfy { alnum($0) || $0 == 46 || $0 == 45 }
    }

    /// Whether text is an IP address or a host name.
    public static func host(_ h: String) -> Bool {
        !h.isEmpty && h.utf8.count <= 253 && (isIp(h) || isHostName(h))
    }

    /// A listener's address: tcp://host:port, with IPv6 hosts in brackets.
    public static func address(_ kind: SocketKind, _ h: String, _ port: Int) -> String {
        let name = h.contains(":") ? "[" + h + "]" : h
        return kind.scheme + "://" + name + ":" + String(port)
    }

    /// The host and port of a peer's address of the right kind, or nil.
    public static func endpoint(_ kind: SocketKind, _ peer: String) -> (String, Int)? {
        let prefix = kind.scheme + "://"
        guard peer.hasPrefix(prefix) else { return nil }
        let authority = String(peer.dropFirst(prefix.count))
        guard !authority.isEmpty, !authority.contains("/"), !authority.contains("?"), !authority.contains("@"),
              !authority.contains("#"), let colon = authority.lastIndex(of: ":") else { return nil }
        var h = String(authority[..<colon])
        let portText = String(authority[authority.index(after: colon)...])
        guard !portText.isEmpty, portText.utf8.count <= 5, portText.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let port = Int(portText), port > 0, port <= 65535 else { return nil }
        if h.hasPrefix("[") {
            guard h.hasSuffix("]") else { return nil }
            h = String(h.dropFirst().dropLast())
        } else if h.contains(":") {
            return nil
        }
        return host(h) ? (h, port) : nil
    }

    public static func request(_ peer: String, _ bytes: [UInt8]) -> [UInt8] {
        let authority = String(peer.dropFirst("http://".count))
        let head = "POST /lawspec HTTP/1.1\r\nHost: " + authority + "\r\nContent-Type: application/octet-stream\r\nContent-Length: "
            + String(bytes.count) + "\r\nConnection: close\r\n\r\n"
        return Array(head.utf8) + bytes
    }

    public static func response(_ code: Int) -> [UInt8] {
        let reason: String
        switch code {
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 411: reason = "Length Required"
        case 413: reason = "Content Too Large"
        case 417: reason = "Expectation Failed"
        default: reason = "Request Header Fields Too Large"
        }
        return Array(("HTTP/1.1 " + String(code) + " " + reason + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").utf8)
    }

    /// The parse of an HTTP head so far.
    public enum Head: Equatable {
        case more
        case failed(Int)
        case body(size: Int, rest: [UInt8])
    }

    private static func headEnd(_ bytes: [UInt8]) -> Int {
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 { return i }
            i += 1
        }
        return -1
    }

    private static func lines(_ bytes: [UInt8], _ end: Int) -> [String] {
        let text = String(decoding: bytes[0..<end].map { $0 < 128 ? $0 : 63 }, as: UTF8.self)
        return text.components(separatedBy: "\r\n")
    }

    private static func headers(_ lines: ArraySlice<String>) -> [String: String]? {
        if lines.count > 101 { return nil }
        var fields = [String: String]()
        for line in lines {
            guard let at = line.firstIndex(of: ":") else { return nil }
            let name = line[..<at].trimmingCharacters(in: .whitespaces).lowercased()
            if name.isEmpty || name.contains(" ") { return nil }
            if fields[name] != nil && (name == "content-length" || name == "transfer-encoding") { return nil }
            if fields[name] == nil { fields[name] = line[line.index(after: at)...].trimmingCharacters(in: .whitespaces) }
        }
        return fields
    }

    /// A request's head: the body size and the bytes after the head.
    public static func header(_ bytes: [UInt8], _ maximum: Int) -> Head {
        let at = headEnd(bytes)
        if at < 0 { return bytes.count < 16384 ? .more : .failed(431) }
        if at + 4 > 16384 { return .failed(431) }
        let all = lines(bytes, at)
        let parts = all[0].components(separatedBy: " ")
        let rest = Array(bytes[(at + 4)...])
        if parts.count != 3 || !(parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0") { return .failed(400) }
        if parts[0] != "POST" { return .failed(405) }
        if parts[1] != "/lawspec" { return .failed(404) }
        guard let fields = headers(all[1...]) else { return .failed(400) }
        if fields["transfer-encoding"] != nil { return .failed(400) }
        if fields["expect"] != nil { return .failed(417) }
        guard let v = fields["content-length"] else { return .failed(411) }
        guard !v.isEmpty, v.utf8.count <= 10, v.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let size = Int64(v) else { return .failed(400) }
        return size <= Int64(maximum) ? .body(size: Int(size), rest: rest) : .failed(413)
    }

    /// Whether a reply head is a 204: nil for more, or the answer.
    public static func reply(_ bytes: [UInt8]) -> Bool? {
        let at = headEnd(bytes)
        if at < 0 { return bytes.count < 16384 ? nil : false }
        let all = lines(bytes, at)
        let parts = all[0].components(separatedBy: " ")
        return parts.count >= 2 && parts[0].hasPrefix("HTTP/1.") && parts[1] == "204" && headers(all[1...]) != nil
    }
}

/// Blocking POSIX socket calls, each bounded by a timeout or a stop check.
enum Sockets {
    static func close(_ fd: Int32) { _ = Darwin.close(fd) }

    private static func noSignal(_ fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// The addresses of a host and port.
    private static func resolve(_ host: String, _ port: Int, passive: Bool) -> [(Int32, Data)] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        if passive { hints.ai_flags = AI_PASSIVE }
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var out = [(Int32, Data)]()
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if let addr = entry.pointee.ai_addr {
                out.append((entry.pointee.ai_family, Data(bytes: addr, count: Int(entry.pointee.ai_addrlen))))
            }
            cursor = entry.pointee.ai_next
        }
        // IPv4 first, as the other targets bind it.
        return out.filter { $0.0 == AF_INET } + out.filter { $0.0 != AF_INET }
    }

    /// A listening socket and its port.
    static func listen(_ host: String, _ port: Int) throws -> (Int32, Int) {
        for (family, address) in resolve(host, port, passive: true) {
            let fd = socket(family, SOCK_STREAM, 0)
            if fd < 0 { continue }
            var one: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            let bound = address.withUnsafeBytes { raw in
                bind(fd, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(address.count))
            }
            if bound != 0 || Darwin.listen(fd, 128) != 0 {
                close(fd)
                continue
            }
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let actual: Int = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
                if Int32(pointer.pointee.ss_family) == AF_INET {
                    return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin_port)) }
                }
                return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin6_port)) }
            }
            return (fd, actual)
        }
        throw Fail.with("InvalidTransportOptions", "cannot listen on " + host + ":" + String(port))
    }

    /// Wait until a socket is readable (or writable): whether it is, within a timeout.
    static func wait(_ fd: Int32, _ events: Int16, _ timeout: Int) -> Bool {
        var entry = pollfd(fd: fd, events: events, revents: 0)
        let n = poll(&entry, 1, Int32(timeout))
        return n > 0
    }

    /// An accepted connection, or nil after a moment with none.
    static func accept(_ fd: Int32) -> Int32? {
        guard wait(fd, Int16(POLLIN), 100) else { return nil }
        let client = Darwin.accept(fd, nil, nil)
        if client < 0 { return nil }
        noSignal(client)
        return client
    }

    /// A connected socket, within a timeout.
    static func connect(_ host: String, _ port: Int, _ timeout: Int) -> Int32? {
        for (family, address) in resolve(host, port, passive: false) {
            let fd = socket(family, SOCK_STREAM, 0)
            if fd < 0 { continue }
            noSignal(fd)
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let started = address.withUnsafeBytes { raw in
                Darwin.connect(fd, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(address.count))
            }
            var ok = started == 0
            if !ok && errno == EINPROGRESS && wait(fd, Int16(POLLOUT), timeout) {
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                ok = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
            }
            _ = fcntl(fd, F_SETFL, flags)
            if ok { return fd }
            close(fd)
        }
        return nil
    }

    /// Write every byte: whether it was written within the timeout.
    static func write(_ fd: Int32, _ bytes: [UInt8], _ timeout: Int) -> Bool {
        var sent = 0
        while sent < bytes.count {
            guard wait(fd, Int16(POLLOUT), timeout) else { return false }
            let n = bytes.withUnsafeBytes { raw in send(fd, raw.baseAddress! + sent, bytes.count - sent, 0) }
            if n <= 0 {
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                return false
            }
            sent += n
        }
        return true
    }

    /// Up to count bytes, waiting while the stop check allows: nil at the end
    /// of the stream, on an error or when stopped.
    static func read(_ fd: Int32, _ count: Int, _ stop: () -> Bool) -> [UInt8]? {
        while !stop() {
            if !wait(fd, Int16(POLLIN), 100) { continue }
            var buffer = [UInt8](repeating: 0, count: count)
            let n = buffer.withUnsafeMutableBytes { raw in recv(fd, raw.baseAddress!, count, 0) }
            if n > 0 { return Array(buffer[0..<n]) }
            if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            return nil
        }
        return nil
    }

    /// Exactly count bytes, or nil.
    static func readExactly(_ fd: Int32, _ count: Int, _ stop: () -> Bool) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(count)
        while out.count < count {
            guard let chunk = read(fd, min(65536, count - out.count), stop) else { return nil }
            out += chunk
        }
        return out
    }
}

/// An owned TCP or HTTP packet listener with per-peer writers that keep each
/// peer's order without blocking the sender. Only the security layer opens
/// these. ref:DEC-distribution-canonical-wire
public final class SocketTransport: @unchecked Sendable {
    static let maxRecord = 67_108_864
    static let ioTimeout = 5000

    private final class Writer: @unchecked Sendable {
        var queue: [[UInt8]] = []
    }

    private struct State {
        var writers: [String: Writer] = [:]
        var closed = false
        var running = 0
    }

    private let kind: SocketKind
    private let receive: @Sendable ([UInt8]) -> Void
    private let listener: Int32
    public let address: String
    private let state = Locked(State())
    private let signal = NSCondition()

    public init(_ kind: SocketKind, _ host: String, _ port: Int, _ advertise: String, _ receive: @escaping @Sendable ([UInt8]) -> Void) throws {
        try Fail.require(port >= 0 && port <= 65535 && SocketProtocol.host(host) && SocketProtocol.host(advertise), "InvalidTransportOptions")
        self.kind = kind
        self.receive = receive
        let (fd, actual) = try Sockets.listen(host, port)
        listener = fd
        address = SocketProtocol.address(kind, advertise, actual)
        work { [self] in acceptLoop() }
    }

    private var stopped: Bool { state.with { $0.closed } }

    /// Run a worker the transport waits for when it closes.
    private func work(_ body: @escaping @Sendable () -> Void) {
        state.with { $0.running += 1 }
        LawThread.start { [self] in
            body()
            state.with { $0.running -= 1 }
        }
    }

    private func acceptLoop() {
        while !stopped {
            guard let client = Sockets.accept(listener) else { continue }
            work { [self] in
                if kind == .tcp { serveTcp(client) } else { serveHttp(client) }
                Sockets.close(client)
            }
        }
        Sockets.close(listener)
    }

    private func serveTcp(_ client: Int32) {
        let stop = { [self] in stopped }
        while !stopped {
            guard let p = Sockets.readExactly(client, 4, stop) else { return }
            let size = Int(p[0]) << 24 | Int(p[1]) << 16 | Int(p[2]) << 8 | Int(p[3])
            if size > SocketTransport.maxRecord { return }
            guard let body = Sockets.readExactly(client, size, stop) else { return }
            receive(body)
        }
    }

    private func serveHttp(_ client: Int32) {
        let deadline = Date().addingTimeInterval(Double(SocketTransport.ioTimeout) / 1000)
        let stop = { [self] in stopped || Date() >= deadline }
        var acc = [UInt8]()
        var head = SocketProtocol.Head.more
        while head == .more {
            guard let chunk = Sockets.read(client, 4096, stop) else { return }
            acc += chunk
            head = SocketProtocol.header(acc, SocketTransport.maxRecord)
        }
        switch head {
        case .body(let size, let rest):
            var body = rest
            if body.count < size {
                guard let tail = Sockets.readExactly(client, size - body.count, stop) else {
                    _ = Sockets.write(client, SocketProtocol.response(400), SocketTransport.ioTimeout)
                    return
                }
                body += tail
            }
            receive(Array(body.prefix(size)))
            _ = Sockets.write(client, SocketProtocol.response(204), SocketTransport.ioTimeout)
        case .failed(let code):
            _ = Sockets.write(client, SocketProtocol.response(code), SocketTransport.ioTimeout)
        case .more:
            return
        }
    }

    /// The next queued record for a peer, waiting up to a minute: nil when idle or closed.
    private func next(_ peer: String, _ writer: Writer) -> [UInt8]? {
        let idle = Date().addingTimeInterval(60)
        signal.lock()
        defer { signal.unlock() }
        while true {
            let item: [UInt8]?? = state.with { s in
                if s.closed {
                    s.writers[peer] = nil
                    return .some(nil)
                }
                if !writer.queue.isEmpty { return .some(writer.queue.removeFirst()) }
                if Date() >= idle {
                    s.writers[peer] = nil
                    return .some(nil)
                }
                return nil
            }
            if let answer = item { return answer }
            _ = signal.wait(until: min(idle, Date().addingTimeInterval(0.2)))
        }
    }

    private func writeTcp(_ peer: String, _ h: String, _ p: Int, _ writer: Writer) {
        var client: Int32? = nil
        defer { if let c = client { Sockets.close(c) } }
        while let bytes = next(peer, writer) {
            let n = bytes.count
            let record = [UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)] + bytes
            var attempts = 2
            while attempts > 0 {
                if client == nil { client = Sockets.connect(h, p, SocketTransport.ioTimeout) }
                if let c = client, Sockets.write(c, record, SocketTransport.ioTimeout) {
                    attempts = 0
                } else {
                    if let c = client { Sockets.close(c) }
                    client = nil
                    attempts -= 1
                }
            }
        }
    }

    private func writeHttp(_ peer: String, _ h: String, _ p: Int, _ writer: Writer) {
        while let bytes = next(peer, writer) {
            guard let client = Sockets.connect(h, p, SocketTransport.ioTimeout) else { continue }
            defer { Sockets.close(client) }
            guard Sockets.write(client, SocketProtocol.request(peer, bytes), SocketTransport.ioTimeout) else { continue }
            let deadline = Date().addingTimeInterval(Double(SocketTransport.ioTimeout) / 1000)
            let stop = { [self] in stopped || Date() >= deadline }
            var acc = [UInt8]()
            while SocketProtocol.reply(acc) == nil {
                guard let chunk = Sockets.read(client, 4096, stop) else { break }
                acc += chunk
            }
        }
    }

    /// Queue bytes for a peer; its writer connects and sends in order. Nil,
    /// or why it was not queued.
    public func send(_ peer: String, _ bytes: [UInt8]) -> String? {
        if bytes.count > SocketTransport.maxRecord { return "record_too_large" }
        guard let (h, p) = SocketProtocol.endpoint(kind, peer) else { return "invalid_peer_address" }
        signal.lock()
        defer { signal.unlock() }
        let outcome: (String?, Writer?) = state.with { s in
            if s.closed { return ("transport_closed", nil) }
            if let writer = s.writers[peer] {
                if writer.queue.count >= 1024 { return ("transport_queue_full", nil) }
                writer.queue.append(bytes)
                return (nil, nil)
            }
            if s.writers.count >= 512 { return ("transport_busy", nil) }
            let writer = Writer()
            writer.queue.append(bytes)
            s.writers[peer] = writer
            return (nil, writer)
        }
        if let writer = outcome.1 {
            let tcp = kind == .tcp
            work { [self] in if tcp { writeTcp(peer, h, p, writer) } else { writeHttp(peer, h, p, writer) } }
        }
        signal.broadcast()
        return outcome.0
    }

    public func close() {
        state.with { $0.closed = true }
        signal.lock()
        signal.broadcast()
        signal.unlock()
        let deadline = Date().addingTimeInterval(5)
        while state.with({ $0.running }) > 0 && Date() < deadline { usleep(5000) }
    }
}
