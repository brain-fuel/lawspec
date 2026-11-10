package lawspec.pekko;

import com.typesafe.config.Config;
import com.typesafe.config.ConfigFactory;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Function;
import java.util.function.Supplier;
import lawspec.runtime.LawSpecRuntime;
import lawspec.runtime.LawSpecRuntime.Value;
import org.apache.pekko.actor.testkit.typed.javadsl.ActorTestKit;
import org.apache.pekko.actor.typed.ActorRef;
import org.apache.pekko.actor.typed.Behavior;
import org.apache.pekko.actor.typed.BehaviorInterceptor;
import org.apache.pekko.actor.typed.RecipientRef;
import org.apache.pekko.actor.typed.SupervisorStrategy;
import org.apache.pekko.actor.typed.Terminated;
import org.apache.pekko.actor.typed.TypedActorContext;
import org.apache.pekko.actor.typed.javadsl.AskPattern;
import org.apache.pekko.actor.typed.javadsl.Behaviors;

/**
 * Checks an existing Pekko Typed actor against a LawSpec actor's model: the model runner drives
 * this backend instead of LawSpec's own actor, with the same runs, crashes, shrinking, invariants
 * on the model and linearizability. The bound behaviour runs unchanged inside an ActorTestKit;
 * each handler is a message asked with AskPattern, and the reply's result is compared with the
 * model. The actor's state stays private: nothing reads it.
 *
 * <p>A crash is a private message, handled after the messages sent before it. A crash
 * interceptor around the behaviour turns it into an exception, so Pekko's own supervision
 * restarts the actor from its behaviour. An event-sourced actor is instead stopped and started
 * again with the same persistence id, and recovers from its journal (the in-memory
 * PersistenceTestKit journal). A reply that does not come within the ask timeout fails the run; it
 * is never a pass.
 *
 * <p>A handler with a caller takes the caller as its first argument: each caller has its own
 * address for the run, and every message from that caller carries it, as an actor's own reference
 * would (the dining hakkers' chopstick knows its hakker by address). A sharded entity's handler
 * takes the entity's id first instead, and is sent through the entity's EntityRef
 * (LawSpecPekkoSharding).
 *
 * <p>The ask timeout is LAWSPEC_ASK_TIMEOUT_MS milliseconds (3000 when not set).
 * ref:DEC-native-actor-binding ref:DEC-pekko-sample-suites
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

  /**
   * Where sharded entities live: the entity of one run with an id, made by the given behaviour from
   * that entity id, through the entity's EntityRef in a one-node cluster.
   */
  public interface Entities
  {
    ActorTestKit testKit();

    RecipientRef<Object> entity(String entityId, Function<String, Behavior<Object>> behavior);
  }

  private interface Handler
  {
    Value call(Map<String, Object> symbols, Spawned actor, List<Value> arguments);
  }

  private static final String HANDLE = "lawspec.pekko";
  private static final AtomicLong IDENTITIES = new AtomicLong();

  private final String actor;
  private final Function<String, Behavior<C>> factory;
  private final boolean persistent;
  private final Map<String, Handler> handlers = new LinkedHashMap<>();
  private final Duration timeout = askTimeout();
  private final Entities entities;
  private final Function<Value, String> entityId;
  private final Map<String, AtomicReference<CompletableFuture<Void>>> restarts =
      new ConcurrentHashMap<>();

  private LawSpecPekkoNative(String actor, Function<String, Behavior<C>> factory,
      boolean persistent, Entities entities, Function<Value, String> entityId)
  {
    this.actor = actor;
    this.factory = factory;
    this.persistent = persistent;
    this.entities = entities;
    this.entityId = entityId;
  }

  private LawSpecPekkoNative(String actor, Function<String, Behavior<C>> factory,
      boolean persistent)
  {
    this(actor, factory, persistent, null, null);
  }

  /** An actor whose behaviour a factory of no arguments makes. */
  public static <C> LawSpecPekkoNative<C> behavior(String actor, Supplier<Behavior<C>> factory)
  {
    return new LawSpecPekkoNative<>(actor, identity -> factory.get(), false);
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

  /**
   * A sharded entity whose factory takes its entity id. Every handler takes the id first, as text
   * that entityId reads; each run's entities are its own.
   */
  public static <C> LawSpecPekkoNative<C> sharded(String actor, Entities entities,
      Function<String, Behavior<C>> factory, Function<Value, String> entityId)
  {
    return new LawSpecPekkoNative<>(actor, factory, false, entities, entityId);
  }

  /** A reply class with type arguments, such as StatusReply of a summary, as the class it is. */
  @SuppressWarnings("unchecked")
  public static <R> Class<R> replyClass(Class<?> raw)
  {
    return (Class<R>) raw;
  }

  /** A caller's address, as the message's address of whatever type it answers. */
  @SuppressWarnings("unchecked")
  public static <R> ActorRef<R> address(ActorRef<?> caller)
  {
    return (ActorRef<R>) caller;
  }

  /** A handler whose message carries a reply address; the reply's result is the handler's. */
  public <R> LawSpecPekkoNative<C> ask(String handler, Message<? extends C, R> message,
      Class<R> reply, Result<? super R> result)
  {
    handlers.put(handler, (symbols, spawned, arguments) -> {
      Object answer = await(AskPattern.<Object, R>ask(target(spawned, arguments),
          replyTo -> message.make(symbols, arguments, replyTo), timeout, system().scheduler()),
          () -> silent(handler, arguments));
      return answered(symbols, handler, arguments, reply, result, answer);
    });
    return this;
  }

  /**
   * A handler whose first argument is its caller: the message carries the caller's own address,
   * and the reply is the next message that address receives. One caller's messages go one at a
   * time, as an actor's would.
   */
  public <R> LawSpecPekkoNative<C> callerAsk(String handler, Message<? extends C, R> message,
      Class<R> reply, Result<? super R> result)
  {
    handlers.put(handler, (symbols, spawned, arguments) -> {
      var caller = spawned.caller(arguments.get(0));
      synchronized (caller)
      {
        caller.inbox.clear();
        target(spawned, arguments).tell(message.make(symbols, arguments, address(caller.ref)));
        Object answer =
            await(caller.next(timeout.toMillis() * 2), () -> silent(handler, arguments));
        return answered(symbols, handler, arguments, reply, result, answer);
      }
    });
    return this;
  }

  /** A handler without a result whose message carries its caller's address, sent at once. */
  public LawSpecPekkoNative<C> callerTell(String handler, Message<? extends C, Object> message)
  {
    handlers.put(handler, (symbols, spawned, arguments) -> {
      var caller = spawned.caller(arguments.get(0));
      synchronized (caller)
      {
        target(spawned, arguments).tell(message.make(symbols, arguments, caller.ref));
      }
      return LawSpecRuntime.absent("Unit");
    });
    return this;
  }

  private String silent(String handler, List<Value> arguments)
  {
    return "native actor " + actor + " did not reply to " + handler + describe(arguments)
        + " within " + timeout.toMillis() + " ms";
  }

  private <R> Value answered(Map<String, Object> symbols, String handler, List<Value> arguments,
      Class<R> reply, Result<? super R> result, Object answer)
  {
    if (!reply.isInstance(answer))
    {
      throw new NativeActorFailure("native actor " + actor + " answered " + handler
          + describe(arguments) + " with " + answer.getClass().getName() + ", not "
          + reply.getName());
    }
    return result.of(symbols, reply.cast(answer));
  }

  /** Where a message goes: the run's actor, or, for a sharded entity, the entity its id names. */
  private RecipientRef<Object> target(Spawned spawned, List<Value> arguments)
  {
    if (entities == null)
    {
      return spawned.ref;
    }
    var id = spawned.identity + "~" + entityId.apply(arguments.get(0));
    spawned.entities.add(id);
    return entities.entity(id, this::entity);
  }

  /**
   * A sharded entity's behaviour, from the entity id the run gave it; the factory sees the id
   * without the run. It restarts in place after a crash, through its own crash interceptor.
   */
  private Behavior<Object> entity(String id)
  {
    var restarted = restarts.computeIfAbsent(id, key -> new AtomicReference<>());
    Behavior<Object> crashing = Behaviors.intercept(
        () -> new CrashInterceptor<C>(restarted, false),
        factory.apply(id.substring(id.indexOf('~') + 1)));
    return Behaviors.supervise(crashing)
        .onFailure(CrashSignal.class, SupervisorStrategy.restart().withLoggingEnabled(false));
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
    handlers.put(handler, (symbols, spawned, arguments) -> {
      target(spawned, arguments).tell(message.make(symbols, arguments));
      return LawSpecRuntime.absent("Unit");
    });
    return this;
  }

  @Override
  public Value spawn(Map<String, Object> symbols, List<Value> startArguments)
  {
    if (entities != null)
    {
      // A run's entities start when they are first sent a message.
      return LawSpecRuntime.handle(HANDLE,
          new Spawned("run" + IDENTITIES.incrementAndGet(), null, testKit()));
    }
    var identity = actor + "-" + IDENTITIES.incrementAndGet();
    return LawSpecRuntime.handle(HANDLE, new Spawned(identity, start(identity), testKit()));
  }

  /**
   * One incarnation of the actor. A behaviour without persistence restarts in place, through the
   * supervision around the crash interceptor; an event-sourced one stops at a crash, and the next
   * incarnation recovers from the journal.
   */
  private ActorRef<Object> start(String identity)
  {
    var restarted = new AtomicReference<CompletableFuture<Void>>();
    Behavior<Object> crashing = Behaviors.intercept(
        () -> new CrashInterceptor<C>(restarted, persistent), factory.apply(identity));
    return testKit().spawn(persistent ? crashing : Behaviors.supervise(crashing)
        .onFailure(CrashSignal.class, SupervisorStrategy.restart().withLoggingEnabled(false)));
  }

  @Override
  public Value call(Map<String, Object> symbols, Value actor, String handler,
      List<Value> arguments)
  {
    var bound = handlers.get(handler);
    if (bound == null)
    {
      throw new IllegalArgumentException("native actor " + this.actor + " has no handler "
          + handler);
    }
    return bound.call(symbols, spawned(actor), List.copyOf(arguments));
  }

  /**
   * The crash follows the messages already sent. An event-sourced actor is then stopped and
   * started again with the same persistence id, as Pekko's EventSourcedBehaviorTestKit restarts
   * one: restarting it in place while it recovers would let the old incarnation's journal replies
   * reach the new one.
   */
  @Override
  public void crash(Map<String, Object> symbols, Value actor)
  {
    var spawned = spawned(actor);
    if (entities != null)
    {
      // Every entity the run has started crashes, and restarts in place.
      for (var id : spawned.entities)
      {
        var restarted = new CompletableFuture<Void>();
        entities.entity(id, this::entity).tell(new Crash(restarted));
        await(restarted, () -> "native entity " + id + " of " + this.actor
            + " did not restart within " + timeout.toMillis() + " ms of a crash");
      }
      return;
    }
    var done = new CompletableFuture<Void>();
    var ref = spawned.ref;
    ref.tell(new Crash(done));
    Supplier<String> late = () -> "native actor " + this.actor + " did not restart within "
        + timeout.toMillis() + " ms of a crash";
    await(done, late);
    if (persistent)
    {
      var stopped = new CompletableFuture<Void>();
      testKit().spawn(Behaviors.setup(context -> {
        context.watch(ref);
        return Behaviors.receive(Object.class)
            .onSignal(Terminated.class, signal -> {
              stopped.complete(null);
              return Behaviors.stopped();
            })
            .build();
      }));
      await(stopped, late);
      spawned.ref = start(spawned.identity);
    }
  }

  @Override
  public Value state(Value actor)
  {
    throw new UnsupportedOperationException(
        "native actor " + this.actor + " keeps its state private");
  }

  /**
   * A run's actor: its persistence id, and its current incarnation; its callers' addresses; and,
   * for sharded entities, the ids of those it has started.
   */
  private static final class Spawned
  {
    final String identity;
    volatile ActorRef<Object> ref;
    final ActorTestKit kit;
    final Map<String, Caller> callers = new ConcurrentHashMap<>();
    final Set<String> entities = ConcurrentHashMap.newKeySet();

    Spawned(String identity, ActorRef<Object> ref, ActorTestKit kit)
    {
      this.identity = identity;
      this.ref = ref;
      this.kit = kit;
    }

    /** The caller a value names, with its own address for the rest of the run. */
    Caller caller(Value who)
    {
      return callers.computeIfAbsent(LawSpecRuntime.render(who), key -> new Caller(kit));
    }
  }

  /** A caller's address, and what it has received there. */
  private static final class Caller
  {
    final BlockingQueue<Object> inbox = new LinkedBlockingQueue<>();
    final ActorRef<Object> ref;

    Caller(ActorTestKit kit)
    {
      ref = kit.spawn(Behaviors.receive(Object.class).onAnyMessage(message -> {
        inbox.add(message);
        return Behaviors.same();
      }).build());
    }

    /** The next message the caller receives, within the given time. */
    CompletableFuture<Object> next(long millis)
    {
      try
      {
        var message = inbox.poll(millis, TimeUnit.MILLISECONDS);
        return message == null ? CompletableFuture.failedFuture(new TimeoutException())
            : CompletableFuture.completedFuture(message);
      }
      catch (InterruptedException error)
      {
        Thread.currentThread().interrupt();
        return CompletableFuture.failedFuture(error);
      }
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
    if (entities != null)
    {
      return entities.testKit();
    }
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
    static final ActorTestKit KIT = started("lawspec-native-journaled", ConfigFactory.parseString(
        "pekko.persistence.testkit.events.serialize = off\n"
            + "pekko.persistence.testkit.snapshots.serialize = off\n")
        .withFallback(common())
        .withFallback(org.apache.pekko.persistence.testkit.PersistenceTestKitPlugin.getInstance()
            .config())
        .withFallback(org.apache.pekko.persistence.testkit.PersistenceTestKitSnapshotPlugin
            .getInstance().config()));
  }

  /** Settings every test kit shares: daemon threads, and quiet restarts. */
  public static Config quiet()
  {
    return common();
  }

  /** The private crash signal, completed once the actor has restarted; only this class sends it. */
  private record Crash(CompletableFuture<Void> restarted)
  {
  }

  /** What the crash interceptor throws, which only the supervision around it restarts on. */
  private static final class CrashSignal extends RuntimeException
  {
    private static final long serialVersionUID = 1L;

    CrashSignal()
    {
      super("LawSpec crash injection", null, false, false);
    }
  }

  /**
   * Turns the private crash signal into an exception inside the actor (or, for an event-sourced
   * actor, stops it) and passes every other message on; when the behaviour restarted after it
   * starts, it tells the crash step.
   *
   * <p>Interim: the pekko-core runtime's LawSpecCrashInterceptor replaces this class when the two
   * merge.
   */
  private static final class CrashInterceptor<C> extends BehaviorInterceptor<Object, C>
  {
    private final AtomicReference<CompletableFuture<Void>> restarted;
    private final boolean stop;

    CrashInterceptor(AtomicReference<CompletableFuture<Void>> restarted, boolean stop)
    {
      super(Object.class);
      this.restarted = restarted;
      this.stop = stop;
    }

    @Override
    public Behavior<C> aroundStart(TypedActorContext<Object> context, PreStartTarget<C> target)
    {
      var started = target.start(context);
      var pending = restarted.getAndSet(null);
      if (pending != null)
      {
        pending.complete(null);
      }
      return started;
    }

    @Override
    @SuppressWarnings("unchecked")
    public Behavior<C> aroundReceive(TypedActorContext<Object> context, Object message,
        ReceiveTarget<C> target)
    {
      if (message instanceof Crash crash)
      {
        if (stop)
        {
          crash.restarted().complete(null);
          return Behaviors.stopped();
        }
        restarted.set(crash.restarted());
        throw new CrashSignal();
      }
      return target.apply(context, (C) message);
    }
  }
}
