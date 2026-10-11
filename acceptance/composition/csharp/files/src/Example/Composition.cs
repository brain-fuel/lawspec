// User-owned LawSpec adapter: native handlers of Logs, Reader and Writer that
// share the case's Store. ref:DEC-acceptance-with-mutants
namespace Example;

using System.Collections.Generic;
using Microsoft.FSharp.Core;
using LawSpec.Abilities.ExampleComposition;
using LawSpec.CSharp;
using LawSpec.Data;

public static class Composition
{
    /// <summary>An in-memory log store: each log's records, newest last.</summary>
    private sealed class LogStore
    {
        public Dictionary<string, List<string>> Logs { get; } = new();
        public bool Open { get; set; } = true;
    }

    private static LogStore Logs(object store) => (LogStore)store;

    public static object OpenStore() => new LogStore();

    public static void CloseStore(object store) => Logs(store).Open = false;

    public static ILogs LogsHandler(object store) => new NativeLogs(Logs(store));

    public static IReader ReaderHandler(object store) => new NativeReader(Logs(store));

    public static IWriter WriterHandler(object store) => new NativeWriter(Logs(store));

    private sealed class NativeLogs(LogStore store) : ILogs
    {
        public void Create(string log) => store.Logs[log] = new List<string>();

        public FSharpResult<long, Problem> Append(string log, string record)
        {
            if (!store.Logs.TryGetValue(log, out var records)) return Outcome.Error<long, Problem>(Problem.UnknownLog);
            if (record == "") return Outcome.Error<long, Problem>(Problem.EmptyRecord);
            records.Add(record);
            return Outcome.Ok<long, Problem>(records.Count - 1);
        }
    }

    private sealed class NativeReader(LogStore store) : IReader
    {
        public FSharpOption<long> Size(string log) =>
            store.Logs.TryGetValue(log, out var records) ? Fn.Some((long)records.Count) : Fn.None<long>();
    }

    private sealed class NativeWriter(LogStore store) : IWriter
    {
        private FSharpOption<long> last = Fn.None<long>();

        public bool Write(string log, string record)
        {
            if (!store.Logs.TryGetValue(log, out var records) || record == "") return false;
            records.Add(record);
            last = Fn.Some((long)(records.Count - 1));
            return true;
        }

        public FSharpOption<long> LastOffset() => last;
    }
}
