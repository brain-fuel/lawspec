/// Services the generated definitions and laws share: contracts, equations,
/// helpers, recordings and concurrent groups. Values stay portable until a
/// native boundary. ref:DEC-typed-core-boundary
module LawSpec.Runtime.Runtime

open System
open System.IO
open System.Threading.Tasks

/// Fail a contract unless it holds.
[<CompiledName("Require")>]
let require (holds: Value) (context: string) =
    match holds with
    | Bool true -> ()
    | Bool false -> Fail.raiseWith "ContractFailed" context
    | _ -> Fail.raiseWith "NonBooleanContract" context

/// An equation of a law: both sides are kept for the report.
[<CompiledName("AssertEqual")>]
let assertEqual (actual: Value) (expected: Value) (label: string) : Value =
    if Scalar.equal actual expected then Bool true
    else Fail.raiseWith "EquationFailed" (sprintf "%s: actual %s, expected %s" label (Recorded.renderPlain actual) (Recorded.renderPlain expected))

/// Name the definition or law a LawSpec failure happened in.
[<CompiledName("Contextual")>]
let contextual (identity: string) (body: unit -> 'a) : 'a =
    try body () with
    | :? LawSpecException as e -> raise (e.Within identity)

let private recordedRoot () =
    match Environment.GetEnvironmentVariable "LAWSPEC_RECORDED" with
    | null | "" ->
        let start = Directory.GetCurrentDirectory()
        let rec find (folder: string) =
            if File.Exists(Path.Combine(folder, "lawspec.json")) || Directory.Exists(Path.Combine(folder, "recorded")) then
                Path.Combine(folder, "recorded")
            else
                match Directory.GetParent folder with
                | null -> Path.Combine(start, "recorded")
                | parent -> find parent.FullName
        find start
    | given -> given

/// Compare a value's text with its recording, or record it under
/// LAWSPEC_UPDATE_RECORDED=1 (lawspec test --update-recorded).
[<CompiledName("RecordedText")>]
let recordedText (key: string) (text: string) : Value =
    let path = Path.Combine(Array.append [| recordedRoot () |] (key.Split '/'))
    if Environment.GetEnvironmentVariable "LAWSPEC_UPDATE_RECORDED" = "1" then
        Directory.CreateDirectory(Path.GetDirectoryName path) |> ignore
        File.WriteAllText(path, text + "\n")
        Bool true
    elif File.Exists path then
        let stored = File.ReadAllText path
        let stored = if stored.EndsWith "\n" then stored.Substring(0, stored.Length - 1) else stored
        if stored = text then Bool true
        else
            Fail.raiseWith "RecordingDiffers"
                ("recorded/" + key + " differs: expected " + stored + ", actual " + text
                 + " (lawspec test --update-recorded records the new value)")
    else
        Fail.raiseWith "RecordingMissing"
            ("no recording recorded/" + key + "; run lawspec test --update-recorded to record " + text)

/// A recorded value, at its type.
[<CompiledName("Recorded")>]
let recorded (key: Value) (value: Value) (t: TypeRef) (schema: Schema.Schema) : Value =
    match key with
    | Text k -> recordedText k (Recorded.text value t (Some schema))
    | _ -> Fail.raiseWith "TextRequired" "recorded"

/// A built-in helper by name.
[<CompiledName("Helper")>]
let helper (name: string) (values: Value list) (types: string list) (bits: int) : Value =
    match name, values with
    | "unreachable", _ -> Fail.raiseWith "Unreachable" ""
    | "regexMatches", [ Text pattern; Text text ] -> Bool(Regex.matches pattern text)
    | "recorded", [ Text key; value ] when List.length types < 2 -> recordedText key (Recorded.renderPlain value)
    | "recorded", [ key; value ] -> recorded key value (Scalar.typeOf (List.item 1 types)) (Schema.create [] [] bits)
    | _ -> Scalar.helper name values types bits

let private unwrap (e: exn) =
    match e with
    | :? AggregateException as a when a.InnerExceptions.Count = 1 -> a.InnerExceptions.[0]
    | _ -> e

/// Run steps concurrently, each on the thread pool, and return their values
/// in source order. Every step finishes before the first failure in source
/// order is raised.
[<CompiledName("Concurrently")>]
let concurrently (steps: (unit -> Value) list) : Value list =
    let tasks = steps |> List.map (fun step -> Task.Run(fun () -> step ())) |> Array.ofList
    try Task.WaitAll(tasks |> Array.map (fun t -> t :> Task)) with _ -> ()
    tasks
    |> Array.map (fun t ->
        if t.IsFaulted then raise (unwrap t.Exception)
        elif t.IsCanceled then Fail.raiseWith "ConcurrentStepCancelled" ""
        else t.Result)
    |> List.ofArray

/// Await an async adapter's task where it is called.
[<CompiledName("Await")>]
let await (task: Task<'a>) : 'a =
    try task.GetAwaiter().GetResult() with e -> raise (unwrap e)
