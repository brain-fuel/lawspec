/// The distribution frame format every target shares: kind, destination,
/// source, request identity and payload, each in the canonical descriptor
/// encoding, so a node on one target talks to a node on another. A received
/// frame never names anything it did not carry.
/// ref:DEC-distribution-canonical-wire
module LawSpec.Runtime.Wire

open System
open System.Numerics
open LawSpec.Runtime.Descriptors

/// A frame: its kind ("call", "chan", "reply", ...), the entity it is for
/// (on send, a full address; on the wire, the name at the peer), the source
/// node's address, the request identity (0 for none) and the payload.
type Frame =
    {
        Kind: string
        To: string
        Source: string
        Id: uint64
        Payload: byte[]
    }

/// A frame to send: the source and identity are filled in by the node.
[<CompiledName("FrameTo")>]
let frameTo (address: string) (kind: string) (payload: byte[]) =
    {
        Kind = kind
        To = address
        Source = ""
        Id = 0UL
        Payload = payload
    }

let private atom name = Forms [ Atom name ]
let internal textType = atom "text"
let internal bytesType = atom "bytes"

let internal identityType =
    Forms
        [
            Atom "int"
            Atom "UInt64"
            Number BigInteger.Zero
            Number(BigInteger UInt64.MaxValue)
        ]

let internal sequenceType =
    Forms
        [
            Atom "int"
            Atom "Int64"
            Number(BigInteger Int64.MinValue)
            Number(BigInteger Int64.MaxValue)
        ]

let private noTable: Map<string, Descriptor> = Map.empty

/// The concatenated canonical encodings of values at their descriptors.
[<CompiledName("Fields")>]
let fields (types: Descriptor list) (values: Value list) : byte[] =
    if List.length types <> List.length values then
        Fail.raiseWith "WireFieldCount" ""

    List.map2 (fun d v -> encode d v noTable) types values |> Array.concat

/// Values read in turn from a position, and the position after them.
[<CompiledName("ReadFields")>]
let readFields (types: Descriptor list) (bytes: byte[]) (start: int) : Value list * int =
    let mutable position = start

    let values =
        [
            for d in types ->
                let v, next = decodePrefix d bytes position noTable
                position <- next
                v
        ]

    values, position

let private text (v: Value) =
    match v with
    | Text s -> s
    | _ -> Fail.raiseWith "InvalidFrame" ""

let private bytesOf (v: Value) =
    match v with
    | Bytes b -> b
    | _ -> Fail.raiseWith "InvalidFrame" ""

/// A frame's bytes.
[<CompiledName("Encode")>]
let encodeFrame (kind: string) (toName: string) (source: string) (identity: uint64) (payload: byte[]) : byte[] =
    fields
        [ textType; textType; textType; identityType; bytesType ]
        [ Text kind; Text toName; Text source; Int(BigInteger identity); Bytes payload ]

/// A frame from exactly its bytes, or None when they are not one.
[<CompiledName("Read")>]
let readFrame (bytes: byte[]) : Frame option =
    try
        match readFields [ textType; textType; textType; identityType; bytesType ] bytes 0 with
        | [ kind; toName; source; Int identity; payload ], next when next = bytes.Length ->
            Some
                {
                    Kind = text kind
                    To = text toName
                    Source = text source
                    Id = uint64 identity
                    Payload = bytesOf payload
                }
        | _ -> None
    with _ ->
        None

/// A channel payload: sequence number, sender address, body.
[<CompiledName("Channel")>]
let channel (sequence: int64) (sender: string) (body: byte[]) : byte[] =
    Array.append (fields [ sequenceType; textType ] [ Int(BigInteger sequence); Text sender ]) body

[<CompiledName("ReadChannel")>]
let readChannel (bytes: byte[]) : int64 * string * byte[] =
    match readFields [ sequenceType; textType ] bytes 0 with
    | [ Int sequence; Text sender ], next -> int64 sequence, sender, bytes.[next..]
    | _ -> Fail.raiseWith "InvalidChannelPayload" ""

[<CompiledName("Sequence")>]
let sequence (n: int64) =
    encode sequenceType (Int(BigInteger n)) noTable

[<CompiledName("ReadSequence")>]
let readSequence (bytes: byte[]) =
    match decode sequenceType bytes noTable with
    | Int n -> int64 n
    | _ -> Fail.raiseWith "InvalidSequence" ""

/// An address's node and entity name: tcp://host:port/name gives
/// (tcp://host:port, name). The node part must have a scheme.
[<CompiledName("SplitAddress")>]
let splitAddress (address: string) : string * string =
    match address.LastIndexOf '/' with
    | -1 -> Fail.raiseWith "InvalidAddress" address
    | at ->
        let node = address.Substring(0, at)

        if not (node.Contains "://") then
            Fail.raiseWith "InvalidAddress" address

        node, address.Substring(at + 1)

/// Text fields of a payload, as the channel protocol's control frames carry them.
let internal texts (values: string list) =
    fields (values |> List.map (fun _ -> textType)) (values |> List.map Text)

let internal readTexts (count: int) (bytes: byte[]) (start: int) =
    let values, next = readFields (List.replicate count textType) bytes start
    values |> List.map text, next

/// A list of texts and the position after it.
let internal readTextList (bytes: byte[]) (start: int) =
    let n, position = readVarint bytes start
    let mutable at = position

    let items =
        [
            for _ in 1 .. int n ->
                let v, next = decodePrefix textType bytes at noTable
                at <- next
                text v
        ]

    items, at

let internal textList (items: string list) =
    encode (Forms [ Atom "list"; textType ]) (Value.List(items |> List.map Text)) noTable

/// A list of byte strings, encoded and read.
let internal bytesList (items: byte[] list) =
    encode (Forms [ Atom "list"; bytesType ]) (Value.List(items |> List.map Bytes)) noTable

let internal readBytesList (bytes: byte[]) (start: int) =
    let n, position = readVarint bytes start
    let mutable at = position

    let items =
        [
            for _ in 1 .. int n ->
                let v, next = decodePrefix bytesType bytes at noTable
                at <- next
                bytesOf v
        ]

    items, at

/// Lowercase hexadecimal of bytes.
let internal hex (bytes: byte[]) =
    Convert.ToHexString(bytes).ToLowerInvariant()
