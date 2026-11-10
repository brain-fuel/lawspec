// User-owned application code: a bank account as a Spring Boot actor
// starter actor, written without LawSpec. lawspec.edn binds it to the
// example.accounts::account actor, whose model checks it.
package example;

import io.github.seonwkim.actor.AskCommand;
import io.github.seonwkim.actor.SpringActor;
import io.github.seonwkim.actor.SpringActorBehavior;
import io.github.seonwkim.actor.SpringActorContext;
import org.springframework.stereotype.Component;

/** An account: deposits add to its balance, which it keeps in memory. */
@Component
public final class AccountActor implements SpringActor<AccountActor.Command>
{
  /** What the account handles. */
  public interface Command
  {
  }

  /** Adds an amount and answers the new balance. */
  public static final class Deposit extends AskCommand<Balance> implements Command
  {
    private final short amount;

    public Deposit(short amount)
    {
      this.amount = amount;
    }
  }

  /** Empties the account and answers what it held. */
  public static final class WithdrawAll extends AskCommand<Balance> implements Command
  {
  }

  /** Answers the balance. */
  public static final class GetBalance extends AskCommand<Balance> implements Command
  {
  }

  /** Empties the account and acknowledges it. */
  public static final class Close extends AskCommand<Closed> implements Command
  {
  }

  /** A balance, as the account answers it. */
  public record Balance(long balance)
  {
  }

  /** The acknowledgement of a close. */
  public record Closed()
  {
  }

  /** The balance of one account actor. */
  private static final class Holding
  {
    private long balance;
  }

  @Override
  public SpringActorBehavior<Command> create(SpringActorContext context)
  {
    return SpringActorBehavior.builder(Command.class, context)
        .withState(behavior -> new Holding())
        .onMessage(Deposit.class, (holding, command) -> {
          holding.balance += command.amount;
          command.reply(new Balance(holding.balance));
          return SpringActorBehavior.same();
        })
        .onMessage(WithdrawAll.class, (holding, command) -> {
          command.reply(new Balance(holding.balance));
          holding.balance = 0L;
          return SpringActorBehavior.same();
        })
        .onMessage(GetBalance.class, (holding, command) -> {
          command.reply(new Balance(holding.balance));
          return SpringActorBehavior.same();
        })
        .onMessage(Close.class, (holding, command) -> {
          holding.balance = 0L;
          command.reply(new Closed());
          return SpringActorBehavior.same();
        })
        .build();
  }
}
