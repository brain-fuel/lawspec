// User-owned LawSpec adapter: adding through a server task, over the typed
// channel ends generated from the Serve and Hire protocols.
module Example.Sessions

open System.Threading.Tasks
open LawSpec.Sessions

// The server: receive two numbers, send their sum.
let private serve (server: Serve.First.ReceiveInt32Step1) =
    let a, afterA = server.Receive()
    let b, afterB = afterA.Receive()
    afterB.Send(int64 a + int64 b) |> ignore

// The client: send both numbers, receive the sum.
let private ask (client: Serve.Second.SendInt32Step1) (a: int) (b: int) : int64 =
    let afterA = client.Send a
    let afterB = afterA.Send b
    fst (afterB.Receive())

let add (value0: int) (value1: int) : Task<bigint> =
    Task.Run(fun () ->
        let first, second = Serve.channel ()
        let server = Task.Run(fun () -> serve first)
        let sum = ask second value0 value1
        server.Wait()
        bigint sum)

// A manager is handed the server's end over a Hire channel and serves it.
let addHired (value0: int) (value1: int) : Task<bigint> =
    Task.Run(fun () ->
        let serverEnd, clientEnd = Serve.channel ()
        let hiring, hired = Hire.channel ()
        let manager = Task.Run(fun () -> serve (fst (hired.Receive())))
        hiring.Send serverEnd |> ignore
        let sum = ask clientEnd value0 value1
        manager.Wait()
        bigint sum)
