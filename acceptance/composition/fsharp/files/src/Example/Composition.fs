// User-owned LawSpec adapter: native handlers of Logs, Reader and Writer that
// share the case's Store. ref:DEC-acceptance-with-mutants
module Example.Composition

open LawSpec.Abilities.ExampleComposition
open LawSpec.Data

/// An in-memory log store: each log's records, newest last.
type LogStore() =
    member val Logs = System.Collections.Generic.Dictionary<string, ResizeArray<string>>()
    member val Open = true with get, set

let private logStore (store: Store) = store :?> LogStore

let openStore () : Store = box (LogStore())

let closeStore (store: Store) : unit = (logStore store).Open <- false

/// The native handler of Logs: create, append.
let logsHandler (store: Store) : ILogs =
    { new ILogs with
        member _.Create(log) = (logStore store).Logs.[log] <- ResizeArray()
        member _.Append(log, record) =
            match (logStore store).Logs.TryGetValue log with
            | false, _ -> Error UnknownLog
            | true, _ when record = "" -> Error EmptyRecord
            | true, records ->
                records.Add record
                Ok(int64 (records.Count - 1)) }

/// The native handler of Reader: size.
let readerHandler (store: Store) : IReader =
    { new IReader with
        member _.Size(log) =
            match (logStore store).Logs.TryGetValue log with
            | true, records -> Some(int64 records.Count)
            | _ -> None }

/// The native handler of Writer: write, lastOffset.
let writerHandler (store: Store) : IWriter =
    let last = ref None
    { new IWriter with
        member _.Write(log, record) =
            match (logStore store).Logs.TryGetValue log with
            | true, records when record <> "" ->
                records.Add record
                last.Value <- Some(int64 (records.Count - 1))
                true
            | _ -> false
        member _.LastOffset() = last.Value }
