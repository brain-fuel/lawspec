// User-owned application code: a bank account as an event-sourced Pekko
// Typed actor, written with the Scala DSL and without LawSpec. lawspec.edn
// binds it to the example.accounts::account actor, whose model checks it.
package example

import org.apache.pekko.Done
import org.apache.pekko.actor.typed.{ActorRef, Behavior}
import org.apache.pekko.persistence.typed.PersistenceId
import org.apache.pekko.persistence.typed.scaladsl.{Effect, EventSourcedBehavior}

/** An account: deposits add to its balance, which survives restarts through its journal. */
object Account {

  /** What the account handles. */
  sealed trait Command

  /** Adds an amount and answers the new balance. */
  final case class Deposit(amount: Short, replyTo: ActorRef[Balance]) extends Command

  /** Empties the account and answers what it held. */
  final case class WithdrawAll(replyTo: ActorRef[Balance]) extends Command

  /** Answers the balance. */
  final case class GetBalance(replyTo: ActorRef[Balance]) extends Command

  /** Empties the account and acknowledges it. */
  final case class Close(replyTo: ActorRef[Done]) extends Command

  /** A balance, as the account answers it. */
  final case class Balance(balance: Long)

  /** What the journal records. */
  sealed trait Event

  /** An amount was added. */
  final case class Deposited(amount: Long) extends Event

  /** The account was emptied. */
  case object Emptied extends Event

  /** The account's state, rebuilt from its events. */
  final case class State(balance: Long)

  /** The account with the given persistence id. */
  def create(id: String): Behavior[Command] =
    EventSourcedBehavior[Command, Event, State](
      PersistenceId.ofUniqueId(id),
      State(0L),
      (state, command) =>
        command match {
          case Deposit(amount, replyTo) =>
            Effect.persist(Deposited(amount)).thenReply(replyTo)(after => Balance(after.balance))
          case WithdrawAll(replyTo) =>
            Effect.persist(Emptied).thenReply(replyTo)(_ => Balance(state.balance))
          case GetBalance(replyTo) => Effect.reply(replyTo)(Balance(state.balance))
          case Close(replyTo) => Effect.persist(Emptied).thenReply(replyTo)(_ => Done)
        },
      (state, event) =>
        event match {
          case Deposited(amount) => State(state.balance + amount)
          case Emptied => State(0L)
        }
    )
}
