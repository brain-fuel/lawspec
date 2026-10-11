// User-owned LawSpec adapter: native handlers for the shop's abilities, and
// a native adapter that fails with a Result.
// ref:DEC-acceptance-with-mutants
namespace Example;

using System.Collections.Generic;
using Microsoft.FSharp.Core;
using LawSpec.Abilities.ExampleAbilities;
using LawSpec.Abilities.ExampleShop;
using LawSpec.CSharp;
using LawSpec.Data;

public static class Shop
{
    public static FSharpResult<int, PaymentError> Refund(IGateway gateway, int cents) =>
        cents > 100000
            ? Outcome.Error<int, PaymentError>(PaymentError.TooLarge)
            : Outcome.Ok<int, PaymentError>(gateway.Capture(cents).Cents);

    /// <summary>The native handler of Log: note.</summary>
    public static ILog LogHandler() => new Log();

    /// <summary>The native handler of Store Int32: load, save.</summary>
    public static IStoreInt32 StoreInt32Handler() => new StoreInt32();

    /// <summary>The native handler of Store Text: load, save.</summary>
    public static IStoreText StoreTextHandler() => new StoreText();

    /// <summary>The native handler of Meter: reading.</summary>
    public static IMeter MeterHandler() => new Meter();

    private sealed class Log : ILog
    {
        private readonly List<string> lines = new();

        public void Note(string text) => lines.Add(text);
    }

    private sealed class StoreInt32 : IStoreInt32
    {
        private int stored;

        public int Load() => stored;

        public void Save(int value) => stored = value;
    }

    private sealed class StoreText : IStoreText
    {
        private string stored = "";

        public string Load() => stored;

        public void Save(string text) => stored = text;
    }

    private sealed class Meter : IMeter
    {
        public int Reading() => 3;
    }
}
