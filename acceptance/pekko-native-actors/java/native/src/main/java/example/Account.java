// User-owned application code: a bank account as an event-sourced Pekko
// Typed actor, written without LawSpec. lawspec.edn binds it to the
// example.accounts::account actor, whose model checks it.
package example;

import org.apache.pekko.Done;
import org.apache.pekko.actor.typed.ActorRef;
import org.apache.pekko.actor.typed.Behavior;
import org.apache.pekko.persistence.typed.PersistenceId;
import org.apache.pekko.persistence.typed.javadsl.CommandHandler;
import org.apache.pekko.persistence.typed.javadsl.EventHandler;
import org.apache.pekko.persistence.typed.javadsl.EventSourcedBehavior;

/** An account: deposits add to its balance, which survives restarts through its journal. */
public final class Account
    extends EventSourcedBehavior<Account.Command, Account.Event, Account.State>
{
  /** What the account handles. */
  public interface Command
  {
  }

  /** Adds an amount and answers the new balance. */
  public record Deposit(short amount, ActorRef<Balance> replyTo) implements Command
  {
  }

  /** Empties the account and answers what it held. */
  public record WithdrawAll(ActorRef<Balance> replyTo) implements Command
  {
  }

  /** Answers the balance. */
  public record GetBalance(ActorRef<Balance> replyTo) implements Command
  {
  }

  /** Empties the account and acknowledges it. */
  public record Close(ActorRef<Done> replyTo) implements Command
  {
  }

  /** A balance, as the account answers it. */
  public record Balance(long balance)
  {
  }

  /** What the journal records. */
  public interface Event
  {
  }

  /** An amount was added. */
  public record Deposited(long amount) implements Event
  {
  }

  /** The account was emptied. */
  public record Emptied() implements Event
  {
  }

  /** The account's state, rebuilt from its events. */
  public record State(long balance)
  {
  }

  private Account(PersistenceId id)
  {
    super(id);
  }

  /** The account with the given persistence id. */
  public static Behavior<Command> create(String id)
  {
    return new Account(PersistenceId.ofUniqueId(id));
  }

  @Override
  public State emptyState()
  {
    return new State(0L);
  }

  @Override
  public CommandHandler<Command, Event, State> commandHandler()
  {
    return newCommandHandlerBuilder()
        .forAnyState()
        .onCommand(Deposit.class, (state, command) -> Effect()
            .persist(new Deposited(command.amount()))
            .thenReply(command.replyTo(), after -> new Balance(after.balance())))
        .onCommand(WithdrawAll.class, (state, command) -> Effect()
            .persist(new Emptied())
            .thenReply(command.replyTo(), after -> new Balance(state.balance())))
        .onCommand(GetBalance.class,
            (state, command) -> Effect().reply(command.replyTo(), new Balance(state.balance())))
        .onCommand(Close.class, (state, command) -> Effect()
            .persist(new Emptied())
            .thenReply(command.replyTo(), after -> Done.done()))
        .build();
  }

  @Override
  public EventHandler<State, Event> eventHandler()
  {
    return newEventHandlerBuilder()
        .forAnyState()
        .onEvent(Deposited.class, (state, event) -> new State(state.balance() + event.amount()))
        .onEvent(Emptied.class, (state, event) -> new State(0L))
        .build();
  }
}
