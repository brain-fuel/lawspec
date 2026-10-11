namespace Warehouse

open System.Threading.Tasks

/// A stock count that several callers may change.
type Shelf() =
    let gate = obj ()
    let mutable total = 0L
    member _.Restock(amount: int) : Task<unit> =
        Task.Run<unit>(fun () -> lock gate (fun () -> total <- total + int64 amount))
    member _.Count() : Task<int64> =
        Task.Run<int64>(fun () -> lock gate (fun () -> total))
