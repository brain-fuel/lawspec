// User-owned LawSpec adapter: a tab's handlers, run inside an actor.
// ref:DEC-acceptance-with-mutants
import Foundation
import LawSpecRuntime

extension Example.Restarts {
    static func openTab() -> Tab { Tab(total: 0) }

    static func add(_ tab: Tab, _ amount: UInt8) -> Pair<Int64, Tab> {
        let after = tab.total + Int64(amount)
        return Pair(first: after, second: Tab(total: after))
    }

    static func total(_ tab: Tab) -> Pair<Int64, Tab> { Pair(first: tab.total, second: tab) }

    /// This unit's tab actor runs these functions.
    private static let handlers = LawSpec.Actors.TabActorHandlers(openTab: openTab, add: add, total: total)

    static func keepsTotal(_ amount: UInt8) -> Int64 {
        let bar = try! LawSpec.Actors.BarSupervisor.start(handlers)
        try! bar.tab.add(amount)
        try! bar.tab.crash()
        let kept = try! bar.tab.total()
        bar.stop()
        return kept
    }
}
