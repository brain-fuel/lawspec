// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
namespace Example;

using System.Threading;
using System.Threading.Tasks;
using LawSpec;
using LawSpec.Data;

public static class Limits
{
    private static Either<string, Ticket> Admitted(Ticket ticket) => Either<string, Ticket>.NewRight(ticket);

    public static Either<string, Ticket> AdmitTicket(Ticket ticket) => Admitted(ticket);

    public static Either<string, Ticket> ReserveSeat(Ticket ticket) => Admitted(ticket);

    public static Either<string, Ticket> ChargeCard(Ticket ticket) =>
        ticket.Number < 0L ? Either<string, Ticket>.NewLeft("declined") : Admitted(ticket);

    public static bool ReleaseSeat(Ticket ticket) => true;

    private static long quotes;

    public static void ResetQuotes() => Interlocked.Exchange(ref quotes, 0L);

    // Ticket -1's quote takes 600ms.
    public static async Task<Either<string, Ticket>> FetchQuote(Ticket ticket)
    {
        if (ticket.Number == -1L) await Task.Delay(600);
        return Admitted(ticket);
    }

    // Ticket -2's first quote (and every other one after) stalls.
    public static async Task<Either<string, Ticket>> HedgeQuote(Ticket ticket)
    {
        if (ticket.Number == -2L && Interlocked.Increment(ref quotes) % 2L == 1L) await Task.Delay(600);
        return Admitted(ticket);
    }
}
