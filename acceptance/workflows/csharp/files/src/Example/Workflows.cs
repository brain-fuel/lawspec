// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
namespace Example;

using System.Collections.Concurrent;
using System.Threading.Tasks;
using LawSpec;
using LawSpec.Data;

public static class Workflows
{
    public static bool Audit(Account account) => true;

    public static Either<SignupError, Account> Waitlist(SignupError error) =>
        error.IsUnavailable
            ? Either<SignupError, Account>.NewRight(new Account("waitlist", 18, 0))
            : Either<SignupError, Account>.NewLeft(error);

    public static Either<SignupError, Signup> CheckName(Signup signup) =>
        signup.Name == "" ? Either<SignupError, Signup>.NewLeft(SignupError.MissingName) : Either<SignupError, Signup>.NewRight(signup);

    public static Either<string, Signup> CheckAge(Signup signup) =>
        signup.Age < 18 ? Either<string, Signup>.NewLeft("too young") : Either<string, Signup>.NewRight(signup);

    public static Either<SignupError, Account> OpenAccount(Signup signup) =>
        signup.Name == "taken"
            ? Either<SignupError, Account>.NewLeft(SignupError.Unavailable)
            : Either<SignupError, Account>.NewRight(new Account(signup.Name, signup.Age, 1));

    /// <summary>Each check records when it fails, so ApprovalErrors can tell
    /// completion order from declaration order.</summary>
    public static readonly ConcurrentQueue<string> Finished = new();

    private static async Task<Either<string, Order>> Check(Order order, int milliseconds, string problem)
    {
        if (order.Number == -1L) await Task.Delay(milliseconds);
        if (order.Number >= 0L) return Either<string, Order>.NewRight(order);
        Finished.Enqueue(problem);
        return Either<string, Order>.NewLeft(problem);
    }

    // Order -1's stock check takes 400ms; a negative order has no stock.
    public static Task<Either<string, Order>> CheckStock(Order order) => Check(order, 400, "no stock");

    // Order -1's credit check takes 250ms; a negative order has no credit.
    public static Task<Either<string, Order>> CheckCredit(Order order) => Check(order, 250, "no credit");
}
