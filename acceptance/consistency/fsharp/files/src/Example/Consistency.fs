// User-owned LawSpec adapter: a page-view counter with one replica per thread.
module Example.Consistency

open System
open System.Collections.Generic
open LawSpec.Data

let private gate = obj ()
let private replicas = Dictionary<int, Dictionary<int, int64>>()
let mutable private ids = 0

let newViews () : Views =
    lock gate (fun () ->
        let id = ids
        ids <- ids + 1
        replicas[id] <- Dictionary()
        { Id = id })

let hit (value0: Views) : int64 =
    lock gate (fun () ->
        let mine = replicas[value0.Id]
        let me = Environment.CurrentManagedThreadId
        let count = (match mine.TryGetValue me with | true, n -> n | _ -> 0L) + 1L
        mine[me] <- count
        count)

let total (value0: Views) : int64 =
    lock gate (fun () -> Seq.sum replicas[value0.Id].Values)
