// User-owned LawSpec adapter: native code that gets the built-in abilities'
// handlers as arguments. ref:DEC-acceptance-with-mutants
module Example.Builtins

open System
open System.Net
open System.Net.Sockets
open LawSpec.Abilities.LawspecHost
open LawSpec.Abilities.LawspecLogging
open LawSpec.Abilities.LawspecRandomness
open LawSpec.Abilities.LawspecTime
open LawSpec.Data

let elapsed (clock: IClock) (count: int) : TimeSpan =
    let start = clock.Now().Value
    for _ in 1 .. count do clock.Now() |> ignore
    TimeSpan.FromTicks((clock.Now().Value - start) * 10L)

let token (secureRandom: ISecureRandom) (count: int) : byte[] = secureRandom.SecureBytes count

let listening (ports: IPorts) (_: int) : bool =
    try
        let listener = new TcpListener(IPAddress.Loopback, ports.FreePort())
        listener.Start()
        listener.Stop()
        true
    with :? SocketException -> false

let charge (log: ILog) (cents: int) : bool =
    if cents % 2 = 0 then
        log.LogMessage(Info, sprintf "charged %d" cents)
        true
    else false
