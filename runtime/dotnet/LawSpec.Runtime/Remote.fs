namespace LawSpec.Runtime

open System
open System.Text

/// One selectable remote function: its arguments' and result's descriptor
/// texts, and (on the serving side) its body over portable values.
type RemoteEntry =
    {
        Arguments: string list
        Result: string
        Invoke: (Value list -> Value) option
    }

/// A connection to a remote service: a node, the service's address, its
/// request kind, the signatures by selector, and the timeout in ms.
type RemoteClient =
    {
        Node: Node
        Address: string
        Kind: string
        Signatures:
            Map<
                string,
                (Map<string, Descriptors.Descriptor> * Descriptors.Descriptor) list *
                (Map<string, Descriptors.Descriptor> * Descriptors.Descriptor)
             >
        Timeout: int
    }

/// Actors and checked definitions answer the same canonical requests: a
/// selector (a message name, or a definition's content hash) and its
/// arguments, each in the canonical wire encoding; the reply is the result.
/// ref:DEC-distribution-canonical-wire ref:DEC-async-native-tasks
module Remote =
    let private fail reason : 'a = Fail.raiseWith "Remote" reason
    let private textType = Descriptors.Forms [ Descriptors.Atom "text" ]

    let private compile (entry: RemoteEntry) =
        entry.Arguments |> List.map Descriptors.fromText, Descriptors.fromText entry.Result

    let private printable (e: exn) =
        Encoding.UTF8.GetBytes(
            match e with
            | :? LawSpecException as l -> l.Message
            | _ -> e.GetType().Name + ": " + e.Message
        )

    /// Serve a table of selectors at a name on a node ("call" for actors,
    /// "eval" for definitions); the service's address.
    [<CompiledName("Serve")>]
    let serve (node: Node) (name: string) (kind: string) (table: (string * RemoteEntry) list) : string =
        if kind <> "call" && kind <> "eval" then
            fail "invalid_kind"

        let compiled =
            table
            |> List.map (fun (selector, entry) ->
                if entry.Invoke.IsNone then
                    fail "invalid_remote_function"

                selector, (compile entry, entry.Invoke.Value))
            |> Map.ofList

        node.RegisterHandler(
            name,
            fun frame ->
                if frame.Kind <> kind then
                    3, Encoding.UTF8.GetBytes "this service does not handle that request kind"
                else
                    let parsed =
                        try
                            match Descriptors.decodePrefix textType frame.Payload 0 Map.empty with
                            | Text selector, start ->
                                let (arguments, result), invoke = compiled.[selector]
                                let mutable at = start

                                let values =
                                    [
                                        for table, d in arguments ->
                                            let v, next = Descriptors.decodePrefix d frame.Payload at table
                                            at <- next
                                            v
                                    ]

                                if at <> frame.Payload.Length then
                                    None
                                else
                                    Some(values, result, invoke)
                            | _ -> None
                        with _ ->
                            None

                    match parsed with
                    | None -> 3, Encoding.UTF8.GetBytes "unknown selector or malformed remote arguments"
                    | Some(values, (table, d), invoke) ->
                        try
                            0, Descriptors.encode d (invoke values) table
                        with
                        | :? LawSpecException as e when e.Code = "ActorStopped" ->
                            2, Encoding.UTF8.GetBytes "the actor has stopped"
                        | e -> 1, printable e
        )

    /// A client of a remote service.
    [<CompiledName("Connect")>]
    let connect
        (node: Node)
        (address: string)
        (kind: string)
        (signatures: (string * RemoteEntry) list)
        (timeout: int)
        : RemoteClient =
        if timeout < 0 then
            fail "invalid_timeout"

        Wire.splitAddress address |> ignore

        {
            Node = node
            Address = address
            Kind = kind
            Timeout = timeout
            Signatures = signatures |> List.map (fun (s, e) -> s, compile e) |> Map.ofList
        }

    /// Call a selector with portable arguments; its portable result.
    [<CompiledName("Call")>]
    let call (client: RemoteClient) (selector: string) (arguments: Value list) : Value =
        let types, (resultTable, resultType) =
            match client.Signatures.TryFind selector with
            | Some s -> s
            | None -> fail ("unknown_selector " + selector)

        if List.length types <> List.length arguments then
            fail "argument_count"

        let payload =
            Array.concat (
                Descriptors.encode textType (Text selector) Map.empty
                :: List.map2 (fun (table, d) v -> Descriptors.encode d v table) types arguments
            )

        match client.Node.Request(client.Address, client.Kind, payload, client.Timeout) with
        | 0, bytes -> Descriptors.decode resultType bytes resultTable
        | 1, message -> fail ("failed " + Encoding.UTF8.GetString message)
        | 2, message -> fail ("stopped " + Encoding.UTF8.GetString message)
        | 3, message -> fail ("rejected " + Encoding.UTF8.GetString message)
        | status, _ -> fail ("invalid_reply_status " + string status)

    /// A program's remotely evaluable definitions: each one's qualified name,
    /// content hash, argument wire forms and result wire form.
    type DefinitionSignature = string * string * string list * string

    /// The functions that evaluate each definition, by name: the generated
    /// LawSpec.Generated.RemoteInvoke, which compiles after the entries, is
    /// found once, by name.
    [<CompiledName("DefinitionInvokers")>]
    let definitionInvokers () : Lazy<Map<string, Value list -> Value>> =
        lazy
            let owner =
                System.AppDomain.CurrentDomain.GetAssemblies()
                |> Array.pick (fun assembly -> Option.ofObj (assembly.GetType "LawSpec.Generated.RemoteInvoke"))

            let property =
                match owner.GetProperty "invokers" with
                | null -> owner.GetProperty "Invokers"
                | p -> p

            let table = property.GetValue(null)
            Map.ofList (table :?> (string * (Value list -> Value)) list)

    let private signatureOf (signatures: DefinitionSignature list) (name: string) =
        match signatures |> List.tryFind (fun (n, _, _, _) -> n = name) with
        | Some signature -> signature
        | None -> fail ("unknown definition " + name)

    /// The content hash of the definition with this qualified name.
    [<CompiledName("DefinitionDigest")>]
    let definitionDigest (signatures: DefinitionSignature list) (name: string) : string =
        let _, hash, _, _ = signatureOf signatures name
        hash

    /// Lets other nodes evaluate the definitions on node; the address they
    /// are served at.
    [<CompiledName("ServeDefinitions")>]
    let serveDefinitions
        (node: Node)
        (signatures: DefinitionSignature list)
        (invokers: Lazy<Map<string, Value list -> Value>>)
        : string =
        serve
            node
            "definitions"
            "eval"
            [
                for name, hash, arguments, result in signatures ->
                    hash,
                    {
                        Arguments = arguments
                        Result = result
                        Invoke = Some invokers.Value.[name]
                    }
            ]

    /// Evaluates the named definition on the node at address, by its content
    /// hash; fails when that node does not answer within timeout.
    [<CompiledName("EvaluateDefinition")>]
    let evaluateDefinition
        (node: Node)
        (signatures: DefinitionSignature list)
        (address: string)
        (name: string)
        (timeout: System.TimeSpan)
        (arguments: Value list)
        : Value =
        let _, hash, types, result = signatureOf signatures name

        let client =
            connect
                node
                (address + "/definitions")
                "eval"
                [
                    hash,
                    {
                        Arguments = types
                        Result = result
                        Invoke = None
                    }
                ]
                (int timeout.TotalMilliseconds)

        call client hash arguments
