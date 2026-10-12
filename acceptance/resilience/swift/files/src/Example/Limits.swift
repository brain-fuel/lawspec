// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
import Foundation
import LawSpecRuntime

/// How many hedged quotes were asked for.
final class Quotes: @unchecked Sendable {
    static let shared = Quotes()
    private let gate = NSLock()
    private var count: Int64 = 0

    func reset() {
        gate.lock()
        count = 0
        gate.unlock()
    }

    func next() -> Int64 {
        gate.lock()
        defer { gate.unlock() }
        count += 1
        return count
    }
}

extension Example.Limits {
    static func admitTicket(_ ticket: Ticket) -> Either<String, Ticket> { .right(ticket) }

    static func reserveSeat(_ ticket: Ticket) -> Either<String, Ticket> { .right(ticket) }

    static func chargeCard(_ ticket: Ticket) -> Either<String, Ticket> {
        ticket.number < 0 ? .left("declined") : .right(ticket)
    }

    static func releaseSeat(_ ticket: Ticket) -> Bool { true }

    static func resetQuotes() { Quotes.shared.reset() }

    /// Ticket -1's quote takes 600ms.
    static func fetchQuote(_ ticket: Ticket) async -> Either<String, Ticket> {
        if ticket.number == -1 { try? await Task.sleep(nanoseconds: 600_000_000) }
        return .right(ticket)
    }

    /// Ticket -2's first quote (and every other one after) stalls.
    static func hedgeQuote(_ ticket: Ticket) async -> Either<String, Ticket> {
        if ticket.number == -2 && Quotes.shared.next() % 2 == 1 { try? await Task.sleep(nanoseconds: 600_000_000) }
        return .right(ticket)
    }
}
