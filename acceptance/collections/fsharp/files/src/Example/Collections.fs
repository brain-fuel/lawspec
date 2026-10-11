// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
module Example.Collections

open LawSpec.Data

let dedupe (value0: int list) : Set<int> = Set.ofList value0

let wordCounts (value0: string list) : Map<string, bigint> =
    value0 |> List.countBy id |> List.map (fun (word, count) -> word, bigint count) |> Map.ofList

let fifo (value0: sbyte list) : Queue<sbyte> = { Queue.Items = value0 }

// A Stack's top is its last item.
let lifo (value0: sbyte list) : Stack<sbyte> = { Stack.Items = value0 }

let rotate (value0: Deque<sbyte>) : Deque<sbyte> =
    match value0.Items with
    | first :: rest -> { Deque.Items = rest @ [ first ] }
    | [] -> value0

// Lists compare by value, so they can be Set elements directly.
let distinctRows (value0: sbyte list list) : Set<sbyte list> = Set.ofList value0
