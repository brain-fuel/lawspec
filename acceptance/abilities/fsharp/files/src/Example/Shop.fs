// User-owned LawSpec adapter: native handlers for the shop's abilities, and
// a native adapter that fails with a Result.
// ref:DEC-acceptance-with-mutants
module Example.Shop

open LawSpec.Abilities.ExampleAbilities
open LawSpec.Abilities.ExampleShop
open LawSpec.Data

/// (Int32 -> Int32)
let refund (gateway: IGateway) (value0: int) : Result<int, PaymentError> =
    if value0 > 100000 then Error TooLarge else Ok (gateway.Capture value0).Cents

/// The native handler of Log: note.
let logHandler () : ILog =
    let lines = ref []
    { new ILog with
        member _.Note(text) = lines.Value <- text :: lines.Value }

/// The native handler of Store Int32: load, save.
let storeInt32Handler () : IStoreInt32 =
    let stored = ref 0
    { new IStoreInt32 with
        member _.Load() = stored.Value
        member _.Save(value) = stored.Value <- value }

/// The native handler of Store Text: load, save.
let storeTextHandler () : IStoreText =
    let stored = ref ""
    { new IStoreText with
        member _.Load() = stored.Value
        member _.Save(text) = stored.Value <- text }

/// The native handler of Meter: reading.
let meterHandler () : IMeter =
    { new IMeter with
        member _.Reading() = 3 }
