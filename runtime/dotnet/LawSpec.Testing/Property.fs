/// Running a law's property: draw cases from a seed, run each, and shrink the
/// first failure to a small counterexample. One seed per run is printed with
/// any failure, and LAWSPEC_SEED replays it. ref:DEC-portable-seeded-generation
/// ref:DEC-never-pass-vacuously
module LawSpec.Testing.Property

open System
open System.Numerics
open LawSpec.Runtime

/// How many cases to run, how many discards a case may take, and how many
/// shrink steps a failure may take.
type Settings =
    { Cases: int
      MaxAttempts: int
      MaxShrinks: int }

let private random = System.Random.Shared

/// The run's seed: LAWSPEC_SEED, or a fresh one.
let runSeed () =
    match Environment.GetEnvironmentVariable "LAWSPEC_SEED" with
    | null | "" -> BigInteger(random.NextInt64())
    | text -> BigInteger.Parse text

let private render (values: Value list) =
    "(" + String.Join(", ", values |> List.map Recorded.renderPlain) + ")"

let private failureOf (property: Value list -> Value) (values: Value list) : exn option =
    try
        match property values with
        | Bool true -> None
        | Bool false -> Some(LawSpecException("PropertyFalse", "") :> exn)
        | other -> Some(LawSpecException("NonBooleanProperty", sprintf "%A" other) :> exn)
    with
    | :? LawSpecException as e when e.Code = "StrategyOutsideRefinement" || e.Code = "StrategyDiscards" -> raise e
    | e -> Some e

/// Check a property over a generator of its inputs.
let check (label: string) (settings: Settings) (gen: Gen<Value list>) (property: Value list -> Value) =
    let seed = runSeed ()
    let mutable state = Random.seed seed
    let mutable passed = 0
    let mutable failure = None
    while failure.IsNone && passed < settings.Cases do
        let size = min 99 passed
        let mutable drawn = None
        let mutable discards = 0
        while drawn.IsNone do
            let s1, s2 = Random.split state
            state <- s2
            match Gen.run gen s1 size with
            | Some tree -> drawn <- Some tree
            | None ->
                discards <- discards + 1
                if discards > settings.MaxAttempts then
                    Harness.abort "CannotSatisfy"
                        (sprintf "%s: no input satisfied the law's domain after %d attempts (seed %O)" label settings.MaxAttempts seed)
        let tree = drawn.Value
        match failureOf property tree.Value with
        | None -> passed <- passed + 1
        | Some error -> failure <- Some(tree, error)
    match failure with
    | None -> ()
    | Some(tree, error) ->
        let mutable best = tree
        let mutable bestError = error
        let mutable steps = 0
        let mutable searching = true
        while searching && steps < settings.MaxShrinks do
            let next =
                best.Children
                |> Seq.truncate (settings.MaxShrinks * 4)
                |> Seq.tryPick (fun child -> failureOf property child.Value |> Option.map (fun e -> child, e))
            match next with
            | Some(child, e) ->
                best <- child
                bestError <- e
                steps <- steps + 1
            | None -> searching <- false
        let message =
            sprintf "%s failed after %d passing case(s) and %d shrink(s): counterexample %s; seed %O (LAWSPEC_SEED=%O replays it)\n%s"
                label passed steps (render best.Value) seed seed bestError.Message
        raise (LawSpecException("PropertyFailed", message, [], bestError))
