// The Swift side of the live cross-target network check
// (tools/swift-network-interoperability.py): a node on TCP through the
// secure transport that serves a mailbox, sends to the other target's
// mailbox and answers what it receives. ref:DEC-distribution-canonical-wire
// ref:DEC-tests-cite-requirements
import Foundation
import LawSpecRuntime

/// An Int64, as the mailboxes on both sides carry it.
let descriptor = "(int Int64 -9223372036854775808 9223372036854775807)"

func run(_ peer: String) throws {
    Crypto.install()
    let node = try Network.openNode(Network.tcp("127.0.0.1", 0), Network.options())
    defer { node.close() }
    let inbox = try Mailbox.serve(node, "swift", descriptor)
    print("address", try inbox.address())
    let outbox = try MailboxSender(node, peer, descriptor, 10_000)
    try outbox.send(.int(41))
    guard let received = try inbox.receive(within: .seconds(10)), case .int(let n) = received else {
        throw Fail.with("Interop", "nothing arrived from the peer")
    }
    try outbox.send(.int(n + 1))
    print("done", n)
}

// Lines reach the driver as they are printed, not when the pipe's buffer fills.
setvbuf(stdout, nil, _IONBF, 0)
do {
    try LawThread.runBlocking { try run(CommandLine.arguments[1]) }
} catch {
    print("failed", error)
    exit(1)
}
