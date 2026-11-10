package lawspec.pekko;

import com.typesafe.config.Config;
import com.typesafe.config.ConfigFactory;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Function;
import java.util.function.Supplier;
import lawspec.runtime.LawSpecRuntime;
import lawspec.runtime.LawSpecRuntime.Value;
import lawspec.runtime.pekko.LawSpecCrashInterceptor;
import org.apache.pekko.actor.testkit.typed.javadsl.ActorTestKit;
import org.apache.pekko.actor.typed.ActorRef;
import org.apache.pekko.actor.typed.Behavior;
import org.apache.pekko.actor.typed.SupervisorStrategy;
import org.apache.pekko.actor.typed.Terminated;
import org.apache.pekko.actor.typed.javadsl.AskPattern;
import org.apache.pekko.actor.typed.javadsl.Behaviors;

/**
 * Checks an existing Pekko Typed actor against a LawSpec actor's model: the model runner drives
 * this backend instead of LawSpec's own actor, with the same runs, crashes, shrinking, invariants
 * on the model and linearizability. The bound behaviour runs unchanged inside an ActorTestKit; each
 * handler is a message asked with AskPattern, and the reply's result is compared with the model.
 * The actor's state stays private: nothing reads it.
 *
 * <p>
 * A crash is a private message, handled after the messages sent before it. A crash interceptor
 * around the behaviour turns it into an exception, so Pekko's own supervision restarts the actor
 * from its behaviour. An event-sourced actor is instead stopped and started again with the same
 * persistence id, and recovers from its journal (the in-memory PersistenceTestKit journal). A reply
 * that does not come within the ask timeout fails the run; it is never a pass.
 *
 * <p>
 * The ask timeout is LAWSPEC_ASK_TIMEOUT_MS milliseconds (3000 when not set).
 * ref:DEC-native-actor-binding
 */
public final class LawSpecPekkoNative<C> implements LawSpecRuntime.ActorBackend
{
  /** A handler's message, made from its arguments (after the state) and the ask's reply address. */
  @FunctionalInterface
  public interface Message<C, R>
  {
    C make(Map<String, Object> symbols, List<Value> arguments, ActorRef<R> replyTo);
  }

  /** A message without a reply address, for a handler whose message nothing answers. */
  @FunctionalInterface
  public interface Notice<C>
  {
    C make(Map<String, Object> symbols, List<Value> arguments);
  }

  /** The LawSpec result a reply carries. */
  @FunctionalInterface
  public interface Result<R>
  {
    Value of(Map<String, Object> symbols, R reply);
  }

  /** A native actor that did not answer in time, or answered with the wrong kind of reply. */
  public static final class NativeActorFailure extends RuntimeException
  {
    private static final long serialVersionUID = 1L;

    NativeActorFailure(String message)
    {
      super(message);
    }
  }

  private interface Handler
  {
    Value call(Map<String, Object> symbols, ActorRef<Object> actor, List<Value> arguments);
  }

  private static final String HANDLE = "lawspec.pekko";
  private static final AtomicLong IDENTITIES = new AtomicLong();

  private final String actor;
  private final Function<String, Behavior<C>> factory;
  private final boolean persistent;
  private final Map<String, Handler> handlers = new LinkedHashMap<>();
  private final Duration timeout = askTimeout();

  private LawSpecPekkoNative(String actor, Function<String, Behavior<C>> factory,
      boolean persistent)
  {
    this.actor = actor;
    this.factory = factory;
    this.persistent = persistent;
  }

  /** An actor whose behaviour a factory of no arguments makes. */
  public static <C> LawSpecPekkoNative<C> behavior(String actor, Supplier<Behavior<C>> factory)
  {
    return new LawSpecPekkoNative<>(actor, identity -> factory.get(), false);
  }

  /**
   * An actor whose factory takes the run's actor identity, the same for each of its restarts, such
   * as a Spring starter actor's id (LawSpecSpringNative).
   */
  public static <C> LawSpecPekkoNative<C> identified(String actor,
      Function<String, Behavior<C>> factory)
  {
    return new LawSpecPekkoNative<>(actor, factory, false);
  }

  /**
   * An event-sourced actor whose factory takes its persistence id; every run's actor gets a fresh
   * one, on the in-memory journal.
   */
  public static <C> LawSpecPekkoNative<C> eventSourced(String actor,
      Function<String, Behavior<C>> factory)
  {
    return new LawSpecPekkoNative<>(actor, factory, true);
  }

  /** A handler whose message carries a reply address; the reply's result is the handler's. */
  public <R> LawSpecPekkoNative<C> ask(String handler, Message<? extends C, R> message,
      Class<R> reply, Result<? super R> result)
  {
    handlers.put(handler, (symbols, ref, arguments) -> {
      Object answer = await(
          AskPattern.<Object, R>ask(ref, replyTo -> message.make(symbols, arguments, replyTo),
              timeout, system().scheduler()),
          () -> "native actor " + actor + " did not reply to " + handler + describe(arguments)
              + " within " + timeout.toMillis() + " ms");
      if (!reply.isInstance(answer))
      {
        throw new NativeActorFailure(
            "native actor " + actor + " answered " + handler + describe(arguments) + " with "
                + answer.getClass().getName() + ", not " + reply.getName());
      }
      return result.of(symbols, reply.cast(answer));
    });
    return this;
  }

  /** A handler without a result whose message is acknowledged with a reply. */
  public <R> LawSpecPekkoNative<C> acknowledged(String handler, Message<? extends C, R> message,
      Class<R> reply)
  {
    return ask(handler, message, reply, (symbols, answer) -> LawSpecRuntime.absent("Unit"));
  }

  /** A handler without a result whose message is sent without waiting. */
  public LawSpecPekkoNative<C> tell(String handler, Notice<? extends C> message)
  {
    handlers.put(handler, (symbols, ref, arguments) -> {
      ref.tell(message.make(symbols, arguments));
      return LawSpecRuntime.absent("Unit");
    });
    return this;
  }

  @Override
  public Value spawn(Map<String, Object> symbols, List<Value> startArguments)
  {
    var identity = actor + "-" + IDENTITIES.incrementAndGet();
    var restarted = new AtomicReference<CompletableFuture<Void>>();
    return LawSpecRuntime.handle(HANDLE,
        new Spawned(identity, restarted, start(identity, restarted)));
  }

  /**
   * One incarnation of the actor, wrapped in LawSpecCrashInterceptor. A behaviour without
   * persistence restarts in place, through the supervision around the interceptor, and tells the
   * pending crash step when it starts again; an event-sourced one stops at a crash, and the next
   * incarnation recovers from the journal.
   */
  private ActorRef<Object> start(String identity,
      AtomicReference<CompletableFuture<Void>> restarted)
  {
    Behavior<C> behavior = Behaviors.setup(context -> {
      var pending = restarted.getAndSet(null);
      if (pending != null)
      {
        pending.complete(null);
      }
      return factory.apply(identity);
    });
    var strategy = persistent ? SupervisorStrategy.stop() : SupervisorStrategy.restart();
    return testKit().spawn(Behaviors.supervise(LawSpecCrashInterceptor.wrap(behavior)).onFailure(
        LawSpecCrashInterceptor.InjectedCrash.class, strategy.withLoggingEnabled(false)));
  }

  @Override
  public Value call(Map<String, Object> symbols, Value actor, String handler, List<Value> arguments)
  {
    var bound = handlers.get(handler);
    if (bound == null)
    {
      throw new IllegalArgumentException(
          "native actor " + this.actor + " has no handler " + handler);
    }
    return bound.call(symbols, spawned(actor).ref, List.copyOf(arguments));
  }

  /**
   * The crash follows the messages already sent. An event-sourced actor is then stopped and started
   * again with the same persistence id, as Pekko's EventSourcedBehaviorTestKit restarts one:
   * restarting it in place while it recovers would let the old incarnation's journal replies reach
   * the new one.
   */
  @Override
  public void crash(Map<String, Object> symbols, Value actor)
  {
    var spawned = spawned(actor);
    var ref = spawned.ref;
    Supplier<String> late = () -> "native actor " + this.actor + " did not restart within "
        + timeout.toMillis() + " ms of a crash";
    if (!persistent)
    {
      var done = new CompletableFuture<Void>();
      spawned.restarted.set(done);
      LawSpecCrashInterceptor.crash(ref, "crash");
      await(done, late);
      return;
    }
    LawSpecCrashInterceptor.crash(ref, "crash");
    var stopped = new CompletableFuture<Void>();
    testKit().spawn(Behaviors.setup(context -> {
      context.watch(ref);
      return Behaviors.receive(Object.class).onSignal(Terminated.class, signal -> {
        stopped.complete(null);
        return Behaviors.stopped();
      }).build();
    }));
    await(stopped, late);
    spawned.ref = start(spawned.identity, spawned.restarted);
  }

  @Override
  public Value state(Value actor)
  {
    throw new UnsupportedOperationException(
        "native actor " + this.actor + " keeps its state private");
  }

  /**
   * A run's actor: its persistence id, the crash step waiting for it to restart, and its current
   * incarnation.
   */
  private static final class Spawned
  {
    final String identity;
    final AtomicReference<CompletableFuture<Void>> restarted;
    volatile ActorRef<Object> ref;

    Spawned(String identity, AtomicReference<CompletableFuture<Void>> restarted,
        ActorRef<Object> ref)
    {
      this.identity = identity;
      this.restarted = restarted;
      this.ref = ref;
    }
  }

  private static Spawned spawned(Value actor)
  {
    return (Spawned) LawSpecRuntime.handleTarget(actor);
  }

  /** The reply, or a failure naming what did not answer: a timeout is never a pass. */
  private <T> T await(java.util.concurrent.CompletionStage<T> pending, Supplier<String> late)
  {
    try
    {
      return pending.toCompletableFuture().get(timeout.toMillis() * 2, TimeUnit.MILLISECONDS);
    }
    catch (TimeoutException error)
    {
      throw new NativeActorFailure(late.get());
    }
    catch (ExecutionException error)
    {
      if (error.getCause() instanceof TimeoutException)
      {
        throw new NativeActorFailure(late.get());
      }
      throw new NativeActorFailure("native actor " + actor + ": " + error.getCause());
    }
    catch (InterruptedException error)
    {
      Thread.currentThread().interrupt();
      throw new NativeActorFailure("interrupted waiting for native actor " + actor);
    }
  }

  private static String describe(List<Value> arguments)
  {
    var parts = new ArrayList<String>();
    for (var argument : arguments)
    {
      parts.add(LawSpecRuntime.render(argument));
    }
    return "(" + String.join(", ", parts) + ")";
  }

  private static Duration askTimeout()
  {
    String text = System.getenv("LAWSPEC_ASK_TIMEOUT_MS");
    return Duration.ofMillis(text == null ? 3000 : Long.parseLong(text.trim()));
  }

  private ActorTestKit testKit()
  {
    return persistent ? Journaled.KIT : Plain.KIT;
  }

  private org.apache.pekko.actor.typed.ActorSystem<Void> system()
  {
    return testKit().system();
  }

  /** Settings both test kits share: daemon threads, and quiet restarts. */
  private static Config common()
  {
    return ConfigFactory.parseString("pekko.daemonic = on\npekko.loglevel = WARNING\n");
  }

  private static ActorTestKit started(String name, Config config)
  {
    var kit = ActorTestKit.create(name, config.withFallback(ConfigFactory.load()));
    Runtime.getRuntime().addShutdownHook(new Thread(kit::shutdownTestKit));
    return kit;
  }

  /** The test kit for actors without persistence. */
  private static final class Plain
  {
    static final ActorTestKit KIT = started("lawspec-native", common());
  }

  /** The test kit for event-sourced actors, on the in-memory journal and snapshot store. */
  private static final class Journaled
  {
    static final ActorTestKit KIT =
        started("lawspec-native-journaled",
            ConfigFactory
                .parseString("pekko.persistence.testkit.events.serialize = off\n"
                    + "pekko.persistence.testkit.snapshots.serialize = off\n")
                .withFallback(common())
                .withFallback(org.apache.pekko.persistence.testkit.PersistenceTestKitPlugin
                    .getInstance().config())
                .withFallback(org.apache.pekko.persistence.testkit.PersistenceTestKitSnapshotPlugin
                    .getInstance().config()));
  }
}
