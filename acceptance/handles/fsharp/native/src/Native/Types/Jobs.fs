namespace Work

open System.Collections.Concurrent

/// The application's job queue, shared between threads.
type Jobs() =
    let queue = ConcurrentQueue<int>()
    member _.Submit(job: int) : unit = queue.Enqueue job
    member _.Take() : int option =
        match queue.TryDequeue() with
        | true, job -> Some job
        | _ -> None
    member _.Pending() : int = queue.Count
