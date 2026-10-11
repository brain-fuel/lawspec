// User-owned LawSpec adapter: a queue, a set and a map shared between
// threads, each one of .NET's own concurrent collections.
module Example.Concurrent

open System.Collections.Concurrent
open System.Threading
open System.Threading.Tasks
open LawSpec.Data

let mutable private ids = 0
let private queues = ConcurrentDictionary<int, ConcurrentQueue<int>>()
let private sets = ConcurrentDictionary<int, ConcurrentDictionary<int, unit>>()
let private maps = ConcurrentDictionary<int, ConcurrentDictionary<sbyte, int64>>()

// A structure by its handle; generated tests may name one first.
let private queue (handle: WorkQueue) = queues.GetOrAdd(handle.Id, fun _ -> ConcurrentQueue())
let private set (handle: Tags) = sets.GetOrAdd(handle.Id, fun _ -> ConcurrentDictionary())
let private map (handle: Cache) = maps.GetOrAdd(handle.Id, fun _ -> ConcurrentDictionary())

let private fresh () = Interlocked.Increment(&ids)

let newQueue () : WorkQueue =
    let handle = { WorkQueue.Id = fresh () }
    queue handle |> ignore
    handle

let offer (value0: WorkQueue) (value1: int) : Task<unit> =
    Task.Run<unit>(fun () -> (queue value0).Enqueue value1)

let poll (value0: WorkQueue) : Task<int option> =
    Task.Run(fun () ->
        let q = queue value0
        match q.TryDequeue() with
        | true, front -> Some front
        | _ -> None)

let queueSize (value0: WorkQueue) : Task<int64> =
    Task.Run(fun () -> int64 (queue value0).Count)

let newTags () : Tags =
    let handle = { Tags.Id = fresh () }
    set handle |> ignore
    handle

let tag (value0: Tags) (value1: int) : Task<bool> =
    Task.Run(fun () -> (set value0).TryAdd(value1, ()))

let untag (value0: Tags) (value1: int) : Task<bool> =
    Task.Run(fun () -> (set value0).TryRemove(value1) |> fst)

let tagged (value0: Tags) (value1: int) : Task<bool> =
    Task.Run(fun () -> (set value0).ContainsKey value1)

let newCache () : Cache =
    let handle = { Cache.Id = fresh () }
    map handle |> ignore
    handle

let private previous (found: bool, value: int64) = if found then Some value else None

let store (value0: Cache) (value1: sbyte) (value2: int64) : Task<int64 option> =
    Task.Run(fun () ->
        let mutable old = None
        (map value0).AddOrUpdate(value1, (fun _ -> old <- None; value2), (fun _ v -> old <- Some v; value2)) |> ignore
        old)

let fetch (value0: Cache) (value1: sbyte) : Task<int64 option> =
    Task.Run(fun () -> previous ((map value0).TryGetValue value1))

let evict (value0: Cache) (value1: sbyte) : Task<int64 option> =
    Task.Run(fun () -> previous ((map value0).TryRemove value1))
