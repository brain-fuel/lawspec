// User-owned LawSpec adapter: a tab's handlers, run inside an actor.
module Example.Restarts

open LawSpec.Data
open LawSpec.Actors

let openTab () : Tab = { Total = 0L }

let add (tab: Tab) (amount: byte) : Pair<int64, Tab> =
    let after = tab.Total + int64 amount
    { First = after; Second = { Total = after } }

let total (tab: Tab) : Pair<int64, Tab> = { First = tab.Total; Second = tab }

/// This unit's tab actor runs these functions.
let private handlers: TabActorHandlers =
    { OpenTab = openTab
      Add = add
      Total = total }

let keepsTotal (amount: byte) : int64 =
    let bar = BarSupervisor.Start handlers
    bar.Tab.Add amount |> ignore
    bar.Tab.Crash()
    let total = bar.Tab.Total()
    bar.Stop()
    total
