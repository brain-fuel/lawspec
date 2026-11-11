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
import lawspec.runtime.pekko.LawSpecCrashInterceptor;
import org.apache.pekko.actor.testkit.typed.javadsl.ActorTestKit;
import org.apache.pekko.actor.typed.ActorRef;
import org.apache.pekko.actor.typed.Behavior;
import org.apache.pekko.actor.typed.RecipientRef;
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
 * A handler with a caller takes the caller as its first argument: each caller has its own address
 * for the run, and every message from that caller carries it, as an actor's own reference would
 * (the dining hakkers' chopstick knows its hakker by address). A sharded entity's handler takes the
 * entity's id first instead, and is sent through the entity's EntityRef (LawSpecPekkoSharding).
 *
 * <p>
 * An actor that answers nothing, such as the dining hakkers' hakker, is observed through probes:
 * addresses of LawSpec's that its factory takes in place of the actors it talks to, as
 * pekko-actor-testkit-typed's TestProbe stands in for them. A handler hears the next message a
 * probe receives, or answers, from the probe, the last message it heard. An actor with a time
 * passes step runs on virtual time (Pekko's ManualTime): its timers fire only when a run's step
 * lets as much time pass as the model says.
 *
 * <p>
 * The ask timeout is LAWSPEC_ASK_TIMEOUT_MS milliseconds (3000 when not set).
 * ref:DEC-native-actor-binding ref:DEC-pekko-sample-suites ref:DEC-tell-only-actors
 * ref:DEC-time-passes
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
  private static final String TIME_PASSES = "timePasses";
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
  private final List<String> probes = new ArrayList<>();
  private final Map<String, Map<String, ActorRef<Object>>> probed = new ConcurrentHashMap<>();
  private boolean timed;
  private ActorTestKit virtual;

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

  /**
   * A sharded entity whose factory takes its entity id. Every handler takes the id first, as text
   * that entityId reads; each run's entities are its own.
   */
  public static <C> LawSpecPekkoNative<C> sharded(String actor, Entities entities,
      Function<String, Behavior<C>> factory, Function<Value, String> entityId)
  {
    return new LawSpecPekkoNative<>(actor, factory, false, entities, entityId);
  }

  /**
   * An actor whose factory takes probes, in the given order of names: each run's actor gets its
   * own, the same for each of its restarts.
   */
  public static <C> LawSpecPekkoNative<C> probed(String actor, List<String> probes,
      Function<Map<String, ActorRef<Object>>, Behavior<C>> factory)
  {
    var made = new AtomicReference<LawSpecPekkoNative<C>>();
    made.set(new LawSpecPekkoNative<>(actor,
        identity -> factory.apply(made.get().probed.get(identity)), false));
    made.get().probes.addAll(probes);
    return made.get();
  }

  /** A reply class with type arguments, such as StatusReply of a summary, as the class it is. */
  @SuppressWarnings("unchecked")
  public static <R> Class<R> replyClass(Class<?> raw)
  {
    return (Class<R>) raw;
  }

  /**
   * The result a reply gives by its class, among a handler's reply cases (the chopstick's Taken is
   * true, Busy false); a reply of any other class fails the run.
   */
  public static <T> T replyCase(Object reply, Map<? extends Class<?>, T> cases)
  {
    for (var entry : cases.entrySet())
    {
      if (entry.getKey().isInstance(reply))
      {
        return entry.getValue();
      }
    }
    throw new NativeActorFailure("a native actor answered with " + reply.getClass().getName()
        + ", which none of the handler's reply cases names");
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
      Object answer = await(
          AskPattern.<Object, R>ask(target(spawned, arguments),
              replyTo -> message.make(symbols, arguments, replyTo), timeout, system().scheduler()),
          () -> silent(handler, arguments));
      return answered(symbols, handler, arguments, reply, result, answer);
    });
    return this;
  }

  /**
   * A handler whose first argument is its caller: the message carries the caller's own address, and
   * the reply is the next message that address receives. One caller's messages go one at a time, as
   * an actor's would.
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
      throw new NativeActorFailure(
          "native actor " + actor + " answered " + handler + describe(arguments) + " with "
              + answer.getClass().getName() + ", not " + reply.getName());
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
   * without the run. It restarts in place after a crash, through LawSpecCrashInterceptor.
   */
  private Behavior<Object> entity(String id)
  {
    var restarted = restarts.computeIfAbsent(id, key -> new AtomicReference<>());
    return crashing(restarted, false, () -> factory.apply(id.substring(id.indexOf('~') + 1)));
  }

  /**
   * The behaviour factory makes, wrapped in LawSpecCrashInterceptor under supervision that restarts
   * it in place after an injected crash (or, for an event-sourced actor, stops it). Each start
   * tells the crash step waiting for it.
   */
  private static <C> Behavior<Object> crashing(AtomicReference<CompletableFuture<Void>> restarted,
      boolean stop, Supplier<Behavior<C>> factory)
  {
    Behavior<C> behavior = Behaviors.setup(context -> {
      var pending = restarted.getAndSet(null);
      if (pending != null)
      {
        pending.complete(null);
      }
      return factory.get();
    });
    var strategy = stop ? SupervisorStrategy.stop() : SupervisorStrategy.restart();
    return Behaviors.supervise(LawSpecCrashInterceptor.wrap(behavior))
        .onFailure(LawSpecCrashInterceptor.InjectedCrash.class, strategy.withLoggingEnabled(false));
  }

  /** A handler without a result whose message is acknowledged with a reply. */
  public <R> LawSpecPekkoNative<C> acknowledged(String handler, Message<? extends C, R> message,
      Class<R> reply)
  {
    return ask(handler, message, reply, (symbols, answer) -> LawSpecRuntime.absent("Unit"));
  }

  /**
   * A handler that hears the next message a probe receives, which must be of the given class; its
   * result is read from that message. Nothing is sent. A probe that hears nothing within the ask
   * timeout fails the run.
   */
  public <H> LawSpecPekkoNative<C> hears(String handler, String probe, Class<H> heard,
      Result<? super H> result)
  {
    handlers.put(handler, (symbols, spawned, arguments) -> {
      var at = spawned.probe(probe);
      synchronized (at)
      {
        Object message = await(at.next(timeout.toMillis() * 2), () -> "native actor " + actor
            + " sent nothing to probe " + probe + " within " + timeout.toMillis() + " ms ("
            + handler + ")");
        at.heard = message;
        if (!heard.isInstance(message))
        {
          throw new NativeActorFailure("native actor " + actor + " sent " + name(message)
              + " to probe " + probe + ", not " + heard.getSimpleName() + " (" + handler + ")");
        }
        return result.of(symbols, heard.cast(message));
      }
    });
    return this;
  }

  /** A handler without a result that hears a message of the given class at a probe. */
  public <H> LawSpecPekkoNative<C> hears(String handler, String probe, Class<H> heard)
  {
    return hears(handler, probe, heard, (symbols, message) -> LawSpecRuntime.absent("Unit"));
  }

  /**
   * A handler that answers, from a probe, the last message the probe heard: that message must be
   * of the given class, and the answer goes to the address its field holds. The answer carries the
   * probe's own address when the message takes one, as a chopstick's answer carries the
   * chopstick.
   */
  public <H, A> LawSpecPekkoNative<C> answers(String handler, String probe, Class<H> heard,
      Function<H, ActorRef<A>> to, Message<? extends A, Object> message)
  {
    handlers.put(handler, (symbols, spawned, arguments) -> {
      var at = spawned.probe(probe);
      synchronized (at)
      {
        Object last = at.heard;
        if (!heard.isInstance(last))
        {
          throw new NativeActorFailure("probe " + probe + " of native actor " + actor
              + " has heard no " + heard.getSimpleName() + " to answer (" + handler + ")");
        }
        to.apply(heard.cast(last)).tell(message.make(symbols, arguments, at.ref));
      }
      return LawSpecRuntime.absent("Unit");
    });
    return this;
  }

  /**
   * The actor's time passes step: the actor runs on virtual time, and each step lets as much time
   * pass as the model's reference says, so the actor's timers due by then fire. It runs only in
   * sequential runs, where the model's result is known before the step.
   */
  public LawSpecPekkoNative<C> timePasses()
  {
    timed = true;
    handlers.put(TIME_PASSES, (symbols, spawned, arguments) -> {
      if (!(symbols.get(LawSpecRuntime.EXPECTED_RESULT) instanceof Value amount))
      {
        throw new NativeActorFailure("time passes for native actor " + actor
            + " only in a sequential run, where the model says how long");
      }
      var micros = (java.math.BigInteger) ((LawSpecRuntime.Data) amount.data()).fields().get(0)
          .data();
      org.apache.pekko.actor.testkit.typed.javadsl.ManualTime.get(system())
          .timePasses(Duration.ofNanos(micros.multiply(java.math.BigInteger.valueOf(1000))
              .longValueExact()));
      return amount;
    });
    return this;
  }

  @Override
  public boolean sequentialOnly(String handler)
  {
    return timed && handler.equals(TIME_PASSES);
  }

  private static String name(Object message)
  {
    return message.getClass().getSimpleName();
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
      return LawSpecRuntime.handle(HANDLE, new Spawned("run" + IDENTITIES.incrementAndGet(),
          new AtomicReference<>(), null, testKit()));
    }
    var identity = actor + "-" + IDENTITIES.incrementAndGet();
    var restarted = new AtomicReference<CompletableFuture<Void>>();
    // A run's probes are made before its actor, whose factory takes them.
    var own = new LinkedHashMap<String, Probe>();
    var refs = new LinkedHashMap<String, ActorRef<Object>>();
    for (var probe : probes)
    {
      var made = new Probe(testKit());
      own.put(probe, made);
      refs.put(probe, made.ref);
    }
    probed.put(identity, refs);
    var spawned = new Spawned(identity, restarted, null, testKit());
    spawned.probes.putAll(own);
    spawned.ref = start(identity, restarted);
    return LawSpecRuntime.handle(HANDLE, spawned);
  }

  /**
   * One incarnation of the actor, wrapped in LawSpecCrashInterceptor. A behaviour without
   * persistence restarts in place, through the supervision around the interceptor; an event-sourced
   * one stops at a crash, and the next incarnation recovers from the journal.
   */
  private ActorRef<Object> start(String identity,
      AtomicReference<CompletableFuture<Void>> restarted)
  {
    return testKit().spawn(crashing(restarted, persistent, () -> factory.apply(identity)));
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
    return bound.call(symbols, spawned(actor), List.copyOf(arguments));
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
    if (entities != null)
    {
      // Every entity the run has started crashes, and restarts in place.
      for (var id : spawned.entities)
      {
        var restarted = new CompletableFuture<Void>();
        restarts.computeIfAbsent(id, key -> new AtomicReference<>()).set(restarted);
        entities.entity(id, this::entity).tell(LawSpecCrashInterceptor.signal("crash"));
        await(restarted, () -> "native entity " + id + " of " + this.actor
            + " did not restart within " + timeout.toMillis() + " ms of a crash");
      }
      return;
    }
    var ref = spawned.ref;
    Supplier<String> late = () -> "native actor " + this.actor + " did not restart within "
        + timeout.toMillis() + " ms of a crash";
    if (!persistent)
    {
      var done = new CompletableFuture<Void>();
      spawned.restarted.set(done);
      LawSpecCrashInterceptor.crash(ref, "crash");
      await(done, late);
    }
    else
    {
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
  }

  @Override
  public Value state(Value actor)
  {
    throw new UnsupportedOperationException(
        "native actor " + this.actor + " keeps its state private");
  }

  /**
   * A run's actor: its persistence id, the crash step waiting for it to restart, and its current
   * incarnation; its callers' addresses; and, for sharded entities, the ids of those it has
   * started.
   */
  private static final class Spawned
  {
    final String identity;
    final AtomicReference<CompletableFuture<Void>> restarted;
    volatile ActorRef<Object> ref;
    final ActorTestKit kit;
    final Map<String, Caller> callers = new ConcurrentHashMap<>();
    final Set<String> entities = ConcurrentHashMap.newKeySet();
    final Map<String, Probe> probes = new ConcurrentHashMap<>();

    Spawned(String identity, AtomicReference<CompletableFuture<Void>> restarted,
        ActorRef<Object> ref, ActorTestKit kit)
    {
      this.identity = identity;
      this.restarted = restarted;
      this.ref = ref;
      this.kit = kit;
    }

    /** A probe of the run's actor, by name. */
    Probe probe(String name)
    {
      var probe = probes.get(name);
      if (probe == null)
      {
        throw new IllegalArgumentException("no probe " + name);
      }
      return probe;
    }

    /** The caller a value names, with its own address for the rest of the run. */
    Caller caller(Value who)
    {
      return callers.computeIfAbsent(LawSpecRuntime.render(who), key -> new Caller(kit));
    }
  }

  /** A probe: a caller's address that also keeps the last message it heard, to answer it. */
  private static final class Probe extends Caller
  {
    volatile Object heard;

    Probe(ActorTestKit kit)
    {
      super(kit);
    }
  }

  /** A caller's address, and what it has received there. */
  private static class Caller
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
    if (timed)
    {
      return virtualTime();
    }
    return persistent ? Journaled.KIT : Plain.KIT;
  }

  private org.apache.pekko.actor.typed.ActorSystem<Void> system()
  {
    return testKit().system();
  }

  /**
   * The test kit of an actor with a time passes step, on virtual time: its own, so no other model's
   * steps move its clock.
   */
  private synchronized ActorTestKit virtualTime()
  {
    if (virtual == null)
    {
      virtual = started("lawspec-native-timed",
          org.apache.pekko.actor.testkit.typed.javadsl.ManualTime.config().withFallback(common()));
    }
    return virtual;
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

  /** Settings every test kit shares: daemon threads, and quiet restarts. */
  public static Config quiet()
  {
    return common();
  }
}
