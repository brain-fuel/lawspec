// User-owned LawSpec adapter: an account's handlers, run inside an actor.
namespace Example;

using System.Threading.Tasks;
using LawSpec.Actors;
using LawSpec.Data;
using LawSpec.Generated;

public static class Actors
{
    public static Account OpenAccount() => new(0L);

    public static Pair<long, Account> Deposit(Account account, byte amount)
    {
        var after = account.Balance + amount;
        return new Pair<long, Account>(after, new Account(after));
    }

    public static Pair<long, Account> WithdrawAll(Account account) => new(account.Balance, new Account(0L));

    public static Pair<long, Account> Balance(Account account) => new(account.Balance, account);

    public static Account Close(Account account) => new(0L);

    public static Account Reopen(Account account) => new(account.Balance);

    public static long DepositTwice(byte amount)
    {
        var account = AccountActor.Start(ActorHandlers.Account);
        Task.WaitAll(Task.Run(() => account.Deposit(amount)), Task.Run(() => account.Deposit(amount)));
        var total = account.Balance();
        account.Stop();
        return total;
    }

    public static long SurvivesCrash(byte amount)
    {
        var bank = BankSupervisor.Start(ActorHandlers.Account);
        bank.Account.Deposit(amount);
        bank.Account.Crash();
        var total = bank.Account.Balance();
        bank.Stop();
        return total;
    }
}
