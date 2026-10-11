// User-owned LawSpec adapters for the resources example.
// ref:REQ-law-primitives ref:DEC-acceptance-with-mutants
namespace Example;

using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using Microsoft.FSharp.Core;
using LawSpec.CSharp;

public static class Resources
{
    private static int openCount;

    /// <summary>An in-memory store. At most three may be open at once, so a
    /// store that is never closed is noticed.</summary>
    private sealed class StoreState
    {
        public StoreState()
        {
            if (openCount >= 3) throw new InvalidOperationException("too many open stores: one was never closed");
            openCount++;
        }

        public Dictionary<int, int> Items { get; } = new();

        public bool Open { get; private set; } = true;

        public void Close()
        {
            if (Open)
            {
                Open = false;
                openCount--;
            }
        }
    }

    private static StoreState Store(object value) => (StoreState)value;

    private static StoreState OpenedStore(object value) =>
        Store(value) is { Open: true } store ? store : throw new InvalidOperationException("the store is closed");

    public static object OpenStore() => new StoreState();

    public static void CloseStore(object store) => Store(store).Close();

    public static void ClearStore(object store) => Store(store).Items.Clear();

    public static void Put(object store, int key, int item) => OpenedStore(store).Items[key] = item;

    public static FSharpOption<int> Get(object store, int key) =>
        OpenedStore(store).Items.TryGetValue(key, out var item) ? Fn.Some(item) : Fn.None<int>();

    public static bool IsOpen(object store) => Store(store).Open;

    public static int Size(object store) => Store(store).Items.Count;

    public static void WriteNote(string folder, int note) => File.WriteAllText(Path.Combine(folder, "note.txt"), note.ToString());

    public static FSharpOption<int> ReadNote(string folder)
    {
        var note = Path.Combine(folder, "note.txt");
        return File.Exists(note) ? Fn.Some(int.Parse(File.ReadAllText(note))) : Fn.None<int>();
    }

    public static bool CanListen(int port)
    {
        try
        {
            var listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start();
            listener.Stop();
            return true;
        }
        catch (SocketException)
        {
            return false;
        }
    }

    public static void SetGreeting(int value) => Environment.SetEnvironmentVariable("LAWSPEC_EXAMPLE_GREETING", value.ToString());

    public static FSharpOption<int> Greeting() =>
        Environment.GetEnvironmentVariable("LAWSPEC_EXAMPLE_GREETING") is string text ? Fn.Some(int.Parse(text)) : Fn.None<int>();

    // A pool that is costly to open: this process may open only one, so the
    // suite passes only if the harness shares it (share Pool per unit).
    private static int poolsOpened;

    private sealed class PoolState
    {
        public int Amount { get; set; }
        public bool Open { get; set; } = true;
    }

    private static PoolState Pool(object value) => (PoolState)value;

    public static object OpenPool()
    {
        if (poolsOpened >= 1) throw new InvalidOperationException("a second pool was opened: the harness should share it");
        poolsOpened++;
        return new PoolState();
    }

    public static void DrainPool(object pool) => Pool(pool).Amount = 0;

    public static void ClosePool(object pool) => Pool(pool).Open = false;

    public static void Fill(object pool, int amount)
    {
        var p = Pool(pool);
        if (!p.Open) throw new InvalidOperationException("the pool is closed");
        p.Amount += amount;
    }

    public static int Level(object pool) => Pool(pool).Amount;
}
