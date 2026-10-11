// User-owned LawSpec adapter: the wire encoding, and nodes talking over
// in-memory, TCP and HTTP transports.
namespace Example;

using System;
using System.Linq;
using System.Numerics;
using System.Text;
using System.Threading.Tasks;
using Microsoft.FSharp.Collections;
using LawSpec.Actors;
using LawSpec.CSharp;
using LawSpec.Data;
using LawSpec.Generated;
using LawSpec.Mailboxes;
using LawSpec.Runtime;
using LawSpec.Sessions;
using Remote = LawSpec.RemoteDefinitions;

public static class Distribution
{
    public static FSharpList<string> Encoded(string text, ulong seed, int size, int count) =>
        Network.WireEncoded(text, new BigInteger(seed), size, count);

    public static bool RoundTrips(string text, ulong seed, int size, int count) =>
        Network.WireRoundTrips(text, new BigInteger(seed), size, count);

    private static MemoryNetwork Memory(int seed, double loss, double duplicate, double delay, bool record) =>
        Network.Memory(Network.MemoryOptions(new BigInteger(seed & 0xFFFF), loss, duplicate, delay, record));

    private static Node Open(Transport transport) => Network.Open(transport, Network.Options());

    private static Node Local() => Open(Network.Tcp("127.0.0.1", 0));

    private static long Number(Value value) => value is Value.Int n ? (long)n.Item : throw new InvalidOperationException($"unexpected {value}");

    public static Task<long> RemoteShifted(int x) =>
        Task.Run(() =>
        {
            using var network = Memory(x, 0.2, 0.2, 0.0, false);
            using var here = Open(Network.MemoryTransport(network, "here"));
            using var there = Open(Network.MemoryTransport(network, "there"));
            Remote.Serve(there);
            return Number(Remote.Evaluate(here, there.Address, "example.distribution::shifted", Fn.List(V.Int(x))));
        });

    public static Tally OpenTally() => new(0L);

    public static Pair<long, Tally> Add(Tally tally, byte n)
    {
        var after = tally.Count + n;
        return new Pair<long, Tally>(after, new Tally(after));
    }

    public static Task<long> RemoteAdds(byte n) =>
        Task.Run(() =>
        {
            using var server = Local();
            using var client = Local();
            var actor = TallyActor.Start(ActorHandlers.Tally);
            try
            {
                var address = actor.Serve(server, "tally");
                var tally = TallyActor.Connect(client, address);
                tally.Add(n);
                return tally.Add(n);
            }
            finally
            {
                actor.Stop();
            }
        });

    public static Task<long> RemoteDoubling(int x) =>
        Task.Run(() =>
        {
            using var server = Open(Network.Http("127.0.0.1", 0));
            using var client = Open(Network.Http("127.0.0.1", 0));
            var first = Doubling.Listen(server, "doubling");
            var second = Doubling.Dial(client, server.Address + "/doubling");
            var worker = Task.Run(() =>
            {
                var (got, next) = second.Receive();
                next.Send(2L * got);
            });
            var (reply, _) = first.Send(x).Receive();
            worker.Wait();
            return reply;
        });

    public static Task<long> RemoteLedger(int x) =>
        Task.Run(() =>
        {
            using var here = Local();
            using var there = Local();
            var ledger = LedgerMailbox.Serve(there, "ledger");
            var sender = LedgerMailbox.Connect(here, there.Address + "/ledger");
            sender.Send(x);
            sender.Send(x);
            var timeout = TimeSpan.FromSeconds(5);
            var total = ledger.Receive(timeout) + ledger.Receive(timeout);
            // Nothing more comes, so receiving within a moment gives nothing.
            return ledger.ReceiveWithin(TimeSpan.FromMilliseconds(20)).IsSome() ? -1L : total;
        });

    public static Task<long> RemoteHandoff(int x) =>
        Task.Run(() =>
        {
            using var here = Local();
            using var there = Local();
            // A local conversation on this node; its first end goes to the other.
            var (first, second) = Doubling.Channel();
            var worker = Task.Run(() =>
            {
                var (got, next) = second.Receive();
                next.Send(2L * got);
            });
            var giving = Handoff.Listen(here, "handoff");
            var taking = Handoff.Dial(there, here.Address + "/handoff");
            giving.Send(first);
            var (moved, _) = taking.Receive();
            var (reply, _) = moved.Send(x).Receive();
            worker.Wait();
            return reply;
        });

    public static Task<long> RemoteHandoffOnward(int x) =>
        Task.Run(() =>
        {
            using var network = Memory(x, 0.1, 0.1, 0.005, false);
            var a = Open(Network.MemoryTransport(network, "a"));
            var b = Open(Network.MemoryTransport(network, "b"));
            using var c = Open(Network.MemoryTransport(network, "c"));
            using var d = Open(Network.MemoryTransport(network, "d"));
            try
            {
                // A conversation between A and C, which sends at once; A's end
                // moves to B, then to D, and answers from there.
                var first = Answering.Listen(a, "answering");
                var second = Answering.Dial(c, a.Address + "/answering").Send(x);
                var toB = Passing.Listen(a, "to-b");
                var atB = Passing.Dial(b, a.Address + "/to-b");
                toB.Send(first);
                var (moved, _) = atB.Receive();
                var toD = Passing.Listen(b, "to-d");
                var atD = Passing.Dial(d, b.Address + "/to-d");
                toD.Send(moved);
                var (answering, _) = atD.Receive();
                // The end no longer needs A or B.
                a.Close();
                b.Close();
                var (got, next) = answering.Receive();
                next.Send(2L * got);
                return second.Receive().Item1;
            }
            finally
            {
                a.Close();
                b.Close();
            }
        });

    private static bool Contains(byte[] haystack, byte[] needle) =>
        Enumerable.Range(0, Math.Max(0, haystack.Length - needle.Length + 1))
            .Any(i => haystack.AsSpan(i, needle.Length).SequenceEqual(needle));

    // A definition evaluated on another node: its request names the
    // definition's content hash, which shows on the wire only in the clear.
    public static Task<bool> SealedOnTheWire(int x) =>
        Task.Run(() =>
        {
            const string name = "example.distribution::shifted";
            var digest = Encoding.UTF8.GetBytes(Remote.Digest(name));
            bool? Seen(bool insecure)
            {
                using var network = Memory(x, 0, 0, 0, true);
                Transport Transport(string node) =>
                    insecure ? Network.InsecureMemoryTransportForTests(network, node) : Network.MemoryTransport(network, node);
                using var here = Open(Transport("here"));
                using var there = Open(Transport("there"));
                Remote.Serve(there);
                var result = Remote.Evaluate(here, there.Address, name, Fn.List(V.Int(x)));
                if (Number(result) != x + 1000L) return null;
                return Network.Recorded(network).Any(frame => Contains(frame, digest));
            }
            return Seen(false) == false && Seen(true) == true;
        });

    public static bool HandshakeAgrees(string text) =>
        text.Split(' ') is [var a, var b, var c, var d, var e, var f, var g, var h, var i, var j, var k, var l, var m]
        && Network.HandshakeVector(a, b, c, d, e, f, g, h, i, j, k, l, m);
}
