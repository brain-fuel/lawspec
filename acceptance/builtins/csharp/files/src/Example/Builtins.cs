// User-owned LawSpec adapter: native code that gets the built-in abilities'
// handlers as arguments. ref:DEC-acceptance-with-mutants
namespace Example;

using System;
using System.Net;
using System.Net.Sockets;
using LawSpec.Abilities.LawspecHost;
using LawSpec.Abilities.LawspecLogging;
using LawSpec.Abilities.LawspecRandomness;
using LawSpec.Abilities.LawspecTime;
using LawSpec.Data;

public static class Builtins
{
    public static TimeSpan Elapsed(IClock clock, int count)
    {
        var start = clock.Now().Value;
        for (var i = 0; i < count; i++) clock.Now();
        return TimeSpan.FromTicks((clock.Now().Value - start) * 10L);
    }

    public static byte[] Token(ISecureRandom secureRandom, int count) => secureRandom.SecureBytes(count);

    public static bool Listening(IPorts ports, int attempt)
    {
        try
        {
            var listener = new TcpListener(IPAddress.Loopback, ports.FreePort());
            listener.Start();
            listener.Stop();
            return true;
        }
        catch (SocketException)
        {
            return false;
        }
    }

    public static bool Charge(ILog log, int cents)
    {
        if (cents % 2 != 0) return false;
        log.LogMessage(LogLevel.Info, $"charged {cents}");
        return true;
    }
}
