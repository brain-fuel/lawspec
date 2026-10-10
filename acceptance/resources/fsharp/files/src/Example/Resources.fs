// User-owned LawSpec adapters for the resources example.
// ref:REQ-law-primitives ref:DEC-acceptance-with-mutants
module Example.Resources

open System.IO
open System.Net
open System.Net.Sockets
open LawSpec.Data

let mutable private openCount = 0

/// An in-memory store. At most three may be open at once, so a store that is
/// never closed is noticed.
type StoreState() =
    let items = System.Collections.Generic.Dictionary<int, int>()
    do
        if openCount >= 3 then invalidOp "too many open stores: one was never closed"
        openCount <- openCount + 1
    member val Open = true with get, set
    member _.Items = items
    member this.Close() =
        if this.Open then
            this.Open <- false
            openCount <- openCount - 1

let private store (value: Store) = value :?> StoreState

let openStore () : Store = box (StoreState())

let closeStore (value: Store) : unit = (store value).Close()

let clearStore (value: Store) : unit = (store value).Items.Clear()

let put (value: Store) (key: int) (item: int) : unit =
    let s = store value
    if not s.Open then invalidOp "the store is closed"
    s.Items.[key] <- item

let get (value: Store) (key: int) : int option =
    let s = store value
    if not s.Open then invalidOp "the store is closed"
    match s.Items.TryGetValue key with
    | true, item -> Some item
    | _ -> None

let isOpen (value: Store) : bool = (store value).Open

let size (value: Store) : int = (store value).Items.Count

let writeNote (folder: string) (note: int) : unit = File.WriteAllText(Path.Combine(folder, "note.txt"), string note)

let readNote (folder: string) : int option =
    let note = Path.Combine(folder, "note.txt")
    if File.Exists note then Some(int (File.ReadAllText note)) else None

let canListen (port: int) : bool =
    try
        let listener = TcpListener(IPAddress.Loopback, port)
        listener.Start()
        listener.Stop()
        true
    with :? SocketException -> false

let setGreeting (value: int) : unit = System.Environment.SetEnvironmentVariable("LAWSPEC_EXAMPLE_GREETING", string value)

let greeting () : int option =
    match System.Environment.GetEnvironmentVariable "LAWSPEC_EXAMPLE_GREETING" with
    | null -> None
    | text -> Some(int text)

// A pool that is costly to open: this process may open only one, so the
// suite passes only if the harness shares it (share Pool per unit).
let mutable private poolsOpened = 0

type PoolState() =
    member val Amount = 0 with get, set
    member val Open = true with get, set

let private pool (value: Pool) = value :?> PoolState

let openPool () : Pool =
    if poolsOpened >= 1 then invalidOp "a second pool was opened: the harness should share it"
    poolsOpened <- poolsOpened + 1
    box (PoolState())

let drainPool (value: Pool) : unit = (pool value).Amount <- 0

let closePool (value: Pool) : unit = (pool value).Open <- false

let fill (value: Pool) (amount: int) : unit =
    let p = pool value
    if not p.Open then invalidOp "the pool is closed"
    p.Amount <- p.Amount + amount

let level (value: Pool) : int = (pool value).Amount
