// User-owned LawSpec adapter.

package sample;

import java.util.List;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import lawspec.data.SampleHakkersHakker;
import lawspec.runtime.LawSpecRuntime.Value;
import org.apache.pekko.actor.typed.ActorRef;
import org.apache.pekko.actor.typed.ActorSystem;
import org.apache.pekko.actor.typed.Props;
import org.apache.pekko.actor.typed.javadsl.Behaviors;

/**
 * The hakkers' protocol of Hakker.java, run against the sample's real Chopstick actors: each step
 * sends the chopsticks the messages a hakker would, from that hakker's own address, and reports
 * how they answered. The model's references are partial, so LawSpec only sends a hakker a step
 * it can take now; a step it cannot take would change nothing here.
 */
public final class Hakkers
{
  private static final ActorSystem<Void> SYSTEM = ActorSystem.create(Behaviors.empty(),
      "hakkers", com.typesafe.config.ConfigFactory.parseString("pekko.daemonic = on"));
  private static final AtomicLong NAMES = new AtomicLong();
  private static final long TIMEOUT_MS = 6000;

  private Hakkers()
  {
  }

  private enum Phase
  {
    THINKING, HUNGRY, HAS_LEFT, DENIED_LEFT, HAS_RIGHT, DENIED_RIGHT, EATING
  }

  /** One hakker: its address, what it has received there, and where it is in the protocol. */
  private static final class Seat
  {
    final BlockingQueue<Chopstick.Answer> inbox = new LinkedBlockingQueue<>();
    final ActorRef<Chopstick.Answer> address;
    Phase phase = Phase.THINKING;

    Seat()
    {
      address = SYSTEM.systemActorOf(Behaviors.receive(Chopstick.Answer.class)
          .onAnyMessage(answer -> {
            inbox.add(answer);
            return Behaviors.same();
          })
          .build(), "hakker-" + NAMES.incrementAndGet(), Props.empty());
    }
  }

  /** A table of five hakkers, as DiningHakkers.java seats them, a chopstick between each two. */
  private static final class Table
  {
    final List<ActorRef<Chopstick.Command>> chopsticks = List.of(chopstick(), chopstick(),
        chopstick(), chopstick(), chopstick());
    final List<Seat> seats = List.of(new Seat(), new Seat(), new Seat(), new Seat(), new Seat());

    private static ActorRef<Chopstick.Command> chopstick()
    {
      return SYSTEM.systemActorOf(Chopstick.create(), "chopstick-" + NAMES.incrementAndGet(),
          Props.empty());
    }
  }

  private static int index(SampleHakkersHakker hakker)
  {
    return switch (hakker)
    {
      case SampleHakkersHakker.Ghosh ghosh -> 0;
      case SampleHakkersHakker.Boner boner -> 1;
      case SampleHakkersHakker.Klang klang -> 2;
      case SampleHakkersHakker.Krasser krasser -> 3;
      case SampleHakkersHakker.Manie manie -> 4;
    };
  }

  private static ActorRef<Chopstick.Command> left(Table table, int hakker)
  {
    return table.chopsticks.get(hakker);
  }

  private static ActorRef<Chopstick.Command> right(Table table, int hakker)
  {
    return table.chopsticks.get((hakker + 1) % table.chopsticks.size());
  }

  /** Sends Take from the hakker and waits for the chopstick's answer: taken, or busy. */
  private static boolean take(Seat seat, ActorRef<Chopstick.Command> chopstick)
  {
    seat.inbox.clear();
    chopstick.tell(new Chopstick.Take(seat.address));
    try
    {
      var answer = seat.inbox.poll(TIMEOUT_MS, TimeUnit.MILLISECONDS);
      if (answer == null)
      {
        throw new IllegalStateException("a chopstick did not answer Take");
      }
      return answer.isTaken();
    }
    catch (InterruptedException error)
    {
      Thread.currentThread().interrupt();
      throw new IllegalStateException("interrupted waiting for a chopstick", error);
    }
  }

  private static void put(Seat seat, ActorRef<Chopstick.Command> chopstick)
  {
    chopstick.tell(new Chopstick.Put(seat.address));
  }

  public static java.lang.Object openTable(Value value0)
  {
    return new Table();
  }

  public static void hungry(java.lang.Object value0, SampleHakkersHakker value1)
  {
    var seat = ((Table) value0).seats.get(index(value1));
    synchronized (seat)
    {
      if (seat.phase == Phase.THINKING)
      {
        seat.phase = Phase.HUNGRY;
      }
    }
  }

  public static boolean leftAnswers(java.lang.Object value0, SampleHakkersHakker value1)
  {
    var table = (Table) value0;
    int hakker = index(value1);
    var seat = table.seats.get(hakker);
    synchronized (seat)
    {
      return switch (seat.phase)
      {
        case HUNGRY -> {
          boolean taken = take(seat, left(table, hakker));
          seat.phase = taken ? Phase.HAS_LEFT : Phase.DENIED_LEFT;
          yield taken;
        }
        case HAS_RIGHT -> {
          boolean taken = take(seat, left(table, hakker));
          if (taken)
          {
            seat.phase = Phase.EATING;
          }
          else
          {
            put(seat, right(table, hakker));
            seat.phase = Phase.THINKING;
          }
          yield taken;
        }
        case DENIED_RIGHT -> {
          boolean taken = take(seat, left(table, hakker));
          if (taken)
          {
            put(seat, left(table, hakker));
          }
          seat.phase = Phase.THINKING;
          yield taken;
        }
        default -> false;
      };
    }
  }

  public static boolean rightAnswers(java.lang.Object value0, SampleHakkersHakker value1)
  {
    var table = (Table) value0;
    int hakker = index(value1);
    var seat = table.seats.get(hakker);
    synchronized (seat)
    {
      return switch (seat.phase)
      {
        case HUNGRY -> {
          boolean taken = take(seat, right(table, hakker));
          seat.phase = taken ? Phase.HAS_RIGHT : Phase.DENIED_RIGHT;
          yield taken;
        }
        case HAS_LEFT -> {
          boolean taken = take(seat, right(table, hakker));
          if (taken)
          {
            seat.phase = Phase.EATING;
          }
          else
          {
            put(seat, left(table, hakker));
            seat.phase = Phase.THINKING;
          }
          yield taken;
        }
        case DENIED_LEFT -> {
          boolean taken = take(seat, right(table, hakker));
          if (taken)
          {
            put(seat, right(table, hakker));
          }
          seat.phase = Phase.THINKING;
          yield taken;
        }
        default -> false;
      };
    }
  }

  public static void full(java.lang.Object value0, SampleHakkersHakker value1)
  {
    var table = (Table) value0;
    int hakker = index(value1);
    var seat = table.seats.get(hakker);
    synchronized (seat)
    {
      if (seat.phase == Phase.EATING)
      {
        put(seat, left(table, hakker));
        put(seat, right(table, hakker));
        seat.phase = Phase.THINKING;
      }
    }
  }
}
