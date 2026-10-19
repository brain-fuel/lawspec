// User-owned LawSpec adapter: a persistent stack and an atomic counter.
module Example.Models

open System.Collections.Concurrent
open System.Threading
open System.Threading.Tasks
open LawSpec.Data

let private counters = ConcurrentDictionary<int, int64 ref>()
let mutable private ids = 0

let empty () : Stack = Stack.Empty

let push (value0: sbyte) (value1: Stack) : PushFlow = { State = Push({ Rest = value1; Top = value0 }) }

// The flow signature guarantees a nonempty stack.
let pop (value0: Stack) : PopFlow =
    match value0 with
    | Push({ Rest = rest; Top = top }) -> { Result = top; State = rest }
    | Empty -> invalidArg "value0" "pop needs a nonempty stack"

let peek (value0: Stack) : PeekFlow =
    match value0 with
    | Push({ Rest = _; Top = top }) -> { Result = top; State = value0 }
    | Empty -> invalidArg "value0" "peek needs a nonempty stack"

let newCounter () : Counter =
    let id = Interlocked.Increment(&ids)
    counters[id] <- ref 0L
    { Id = id }

let increment (value0: Counter) : Task<int64> =
    Task.Run(fun () -> Interlocked.Increment(&counters[value0.Id].contents))

let decrement (value0: Counter) : Task<int64> =
    Task.Run(fun () -> Interlocked.Decrement(&counters[value0.Id].contents))

let read (value0: Counter) : Task<int64> =
    Task.Run(fun () -> Interlocked.Read(&counters[value0.Id].contents))
