// User-owned LawSpec adapter: adding through a server task, over the typed
// channel ends generated from the Serve and Hire protocols.
namespace Example;

using System;
using System.Numerics;
using System.Threading.Tasks;
using LawSpec.Sessions;

public static class Sessions
{
    // The server: receive two numbers, send their sum.
    private static void Serve(Serve.First.ReceiveInt32Step1 server)
    {
        var (a, afterA) = server.Receive();
        var (b, afterB) = afterA.Receive();
        afterB.Send((long)a + b);
    }

    // The client: send both numbers, receive the sum.
    private static long Ask(Serve.Second.SendInt32Step1 client, int a, int b)
    {
        var afterA = client.Send(a);
        var afterB = afterA.Send(b);
        return afterB.Receive().Item1;
    }

    public static Task<BigInteger> Add(int a, int b) =>
        Task.Run(() =>
        {
            var (first, second) = LawSpec.Sessions.Serve.Channel();
            var server = Task.Run(() => Serve(first));
            var sum = Ask(second, a, b);
            server.Wait();
            return new BigInteger(sum);
        });

    // A manager is handed the server's end over a Hire channel and serves it.
    public static Task<BigInteger> AddHired(int a, int b) =>
        Task.Run(() =>
        {
            var (serverEnd, clientEnd) = LawSpec.Sessions.Serve.Channel();
            var (hiring, hired) = Hire.Channel();
            var manager = Task.Run(() => Serve(hired.Receive().Item1));
            hiring.Send(serverEnd);
            var sum = Ask(clientEnd, a, b);
            manager.Wait();
            return new BigInteger(sum);
        });
}
