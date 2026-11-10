package lawspec.runtime.pekko;

import com.typesafe.config.Config;
import com.typesafe.config.ConfigFactory;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.CompletionException;
import java.util.function.Consumer;
import java.util.function.Function;
import lawspec.runtime.LawSpecRuntime.ActorCrashed;
import lawspec.runtime.LawSpecRuntime.ActorStopped;
import lawspec.runtime.LawSpecRuntime.Exit;
import lawspec.runtime.LawSpecRuntime.Next;
import org.apache.pekko.actor.typed.ActorRef;
import org.apache.pekko.actor.typed.ActorSystem;
import org.apache.pekko.actor.typed.Behavior;
import org.apache.pekko.actor.typed.PreRestart;
import org.apache.pekko.actor.typed.Props;
import org.apache.pekko.actor.typed.RecipientRef;
import org.apache.pekko.actor.typed.SupervisorStrategy;
import org.apache.pekko.actor.typed.javadsl.AskPattern;
import org.apache.pekko.actor.typed.javadsl.Behaviors;

/**
 * LawSpec actors on Apache Pekko Typed: the actor system, a blocking ask, and Actor, which runs a
 * LawSpec actor's handlers as a Pekko behaviour.
 *
 * <p>
 * An Actor has the methods of LawSpecRuntime.Actor, so the generated actor classes, the user's
 * adapters and the laws are the same on both runtimes. Its state is the LawSpec state value; each
 * message carries the adapter call that gives the reply and the next state. A handler that throws
 * fails the Pekko actor, and Pekko's restart strategy restarts it in place: the reference and the
 * waiting messages survive (ref:pekko-supervision). The PreRestart signal is where the actor asks
 * its LawSpecPekkoSupervisor whether to restart, and with which state, so OTP's strategies,
 * lifetimes and restart limits hold as on LawSpec's own runtime. ref:DEC-pekko-runtime
 * ref:DEC-pekko-otp-supervision ref:pekko-typed-fault-tolerance
 */
public final class LawSpecPekko
{
  private LawSpecPekko()
  {
  }

  /** How long a call waits for its reply unless lawspec.pekko.ask-timeout says otherwise. */
  public static final Duration DEFAULT_ASK_TIMEOUT = Duration.ofSeconds(30);

  private static ActorSystem<Void> system;

  // An actor system another runtime gave (LawSpecSpring's), used instead of system's.
  private static ActorSystem<?> given;

  private static final java.util.concurrent.atomic.AtomicLong NAMES =
      new java.util.concurrent.atomic.AtomicLong();

  /**
   * The actor system every LawSpec actor of this JVM runs in, started on first use. Its threads are
   * daemons and its logging is off: a crash is an expected step of a run, not an error to report.
   */
  public static synchronized ActorSystem<Void> system()
  {
    if (system == null)
    {
      Config quiet =
          ConfigFactory
              .parseString(String.join("\n", "pekko.daemonic = on", "pekko.loglevel = \"OFF\"",
                  "pekko.stdout-loglevel = \"OFF\"", "pekko.log-dead-letters = off",
                  "pekko.log-dead-letters-during-shutdown = off"))
              .withFallback(ConfigFactory.load());
      system = ActorSystem.create(Behaviors.<Void>empty(), "lawspec", quiet);
    }
    return system;
  }

  /**
   * Runs later actors, asks and supervisors in an actor system another runtime started, such as the
   * Spring starter's (LawSpecSpring); null returns to LawSpec's own.
   */
  public static synchronized void use(ActorSystem<?> system)
  {
    given = system;
  }

  /** The actor system later actors run in: the one given to use, or LawSpec's own. */
  private static synchronized ActorSystem<?> current()
  {
    return given != null ? given : system();
  }

  /** Stops the actor system; a later actor starts a new one. */
  public static synchronized void terminate()
  {
    if (system != null)
    {
      system.terminate();
      system.getWhenTerminated().toCompletableFuture().join();
      system = null;
    }
  }

  /**
   * How long a call waits for its reply: the lawspec.pekko.ask-timeout system property (such as 5s
   * or 500ms), or DEFAULT_ASK_TIMEOUT.
   */
  public static Duration askTimeout()
  {
    var given = System.getProperty("lawspec.pekko.ask-timeout");
    if (given == null || given.isBlank())
    {
      return DEFAULT_ASK_TIMEOUT;
    }
    return ConfigFactory.parseString("t = " + given.trim()).getDuration("t");
  }

  /** A call that got no reply within the ask timeout: not a reply, and not a pass. */
  public static final class AskTimedOut extends IllegalStateException
  {
    public AskTimedOut(Duration timeout)
    {
      super("no reply within " + timeout);
    }
  }

  /**
   * Sends the message message makes for a reply address and waits for the reply, at most
   * askTimeout(); throws AskTimedOut when none comes.
   */
  public static <Q, R> R ask(RecipientRef<Q> target,
      org.apache.pekko.japi.function.Function<ActorRef<R>, Q> message)
  {
    var timeout = askTimeout();
    try
    {
      return AskPattern.ask(target, message, timeout, current().scheduler()).toCompletableFuture()
          .join();
    }
    catch (CompletionException e)
    {
      if (e.getCause() instanceof java.util.concurrent.TimeoutException)
      {
        throw new AskTimedOut(timeout);
      }
      if (e.getCause() instanceof RuntimeException runtime)
      {
        throw runtime;
      }
      throw e;
    }
  }

  /** Spawns a top-level actor of the system, named prefix and a number. */
  public static <T> ActorRef<T> spawn(Behavior<T> behavior, String prefix)
  {
    return current().systemActorOf(behavior, prefix + "-" + NAMES.incrementAndGet(), Props.empty());
  }

  /** A message an actor handles: the adapter call, and where its reply goes (none for a tell). */
  private static final class Call
  {
    final Function<Object, ? extends Next<?, Object>> handler;
    final ActorRef<Reply> replyTo;

    Call(Function<Object, ? extends Next<?, Object>> handler, ActorRef<Reply> replyTo)
    {
      this.handler = handler;
      this.replyTo = replyTo;
    }
  }

  /** A call's reply: its value, or why there is none. */
  private record Reply(Object value, RuntimeException failure)
  {
  }

  /** Sent once an actor stops taking messages, so an idle actor ends. */
  private enum Ending
  {
    CHECK
  }

  /**
   * An actor owning a state of type S, handling one message at a time, on Pekko.
   *
   * <p>
   * restart (the last state to the state after a crash) lets a supervisor restart it; without it, a
   * crash stops the actor even under a supervisor. A supervised actor restarts in place: it keeps
   * its reference and the messages waiting for it.
   */
  public static final class Actor<S>
  {
    // The state and the crash in progress belong to the actor's turn; Pekko orders every turn
    // after the previous one.
    private S state;
    private final Function<S, S> restartState;
    private Object crashCause;
    private long crashOrigin;
    private ActorRef<Reply> crashReply;
    private RuntimeException crashFailure;
    private final java.util.Set<Long> seen = java.util.concurrent.ConcurrentHashMap.newKeySet();

    // What senders see: whether it takes messages, and how many it has still to handle.
    private final Object lock = new Object();
    private boolean stopped;
    private boolean halted;
    private int pending;

    private volatile LawSpecPekkoSupervisor supervisor;
    private final List<Consumer<Exit>> monitors = new java.util.concurrent.CopyOnWriteArrayList<>();
    private final List<Actor<?>> links = new java.util.concurrent.CopyOnWriteArrayList<>();
    private final ActorRef<Object> ref;

    public Actor(S state)
    {
      this(state, null);
    }

    public Actor(S state, Function<S, S> restart)
    {
      this(state, restart, behavior -> spawn(behavior, "lawspec-actor"));
    }

    /**
     * An actor spawned by spawner, which runs the actor's behaviour where the runtime that chose it
     * says, such as through the Spring starter's actor system (LawSpecSpring).
     */
    public Actor(S state, Function<S, S> restart,
        Function<Behavior<Object>, ActorRef<Object>> spawner)
    {
      this.state = state;
      this.restartState = restart;
      Behavior<Object> core = Behaviors.setup(context -> running());
      this.ref = spawner.apply(Behaviors
          .supervise(
              Behaviors.intercept(() -> new LawSpecCrashInterceptor<Object>(this::accept), core))
          .onFailure(
              SupervisorStrategy.restart().withStopChildren(false).withLoggingEnabled(false)));
    }

    /** The Pekko reference, which takes LawSpecCrashInterceptor's crash signal. */
    public ActorRef<Object> ref()
    {
      return ref;
    }

    /** On the actor's turn, before a crash signal throws: false for a crash already seen. */
    private boolean accept(LawSpecCrashInterceptor.Crash crash)
    {
      synchronized (lock)
      {
        if (halted || seen.contains(crash.origin()))
        {
          return false;
        }
      }
      crashCause = crash.cause();
      crashOrigin = crash.origin();
      crashReply = null;
      crashFailure = null;
      return true;
    }

    /** The behaviour after a start or a restart. */
    private Behavior<Object> running()
    {
      synchronized (lock)
      {
        if (halted && pending == 0)
        {
          return Behaviors.stopped();
        }
      }
      return Behaviors.receive(Object.class).onMessage(Call.class, this::handle)
          .onMessageEquals(Ending.CHECK, this::ended).onSignal(PreRestart.class, signal -> {
            restarting();
            return Behaviors.same();
          }).build();
    }

    @SuppressWarnings("unchecked")
    private Behavior<Object> handle(Call call)
    {
      boolean refused;
      synchronized (lock)
      {
        refused = halted;
      }
      if (refused)
      {
        reply(call.replyTo, new Reply(null, new ActorStopped("the actor has stopped")));
        handled();
        return ended();
      }
      Next<?, S> next;
      try
      {
        next = ((Function<S, ? extends Next<?, S>>) (Function<?, ?>) call.handler).apply(state);
      }
      catch (Throwable error)
      {
        handled();
        crashCause = error;
        crashOrigin = LawSpecCrashInterceptor.signal(error).origin();
        crashReply = call.replyTo;
        crashFailure = new ActorCrashed(error);
        throw new HandlerFailed(error);
      }
      state = next.state();
      reply(call.replyTo, new Reply(next.reply(), null));
      handled();
      return ended();
    }

    private void handled()
    {
      synchronized (lock)
      {
        pending--;
      }
    }

    /** After a message: the actor ends once it is stopped and has nothing left to handle. */
    private Behavior<Object> ended()
    {
      synchronized (lock)
      {
        if (stopped && pending <= 0)
        {
          return Behaviors.stopped();
        }
      }
      return Behaviors.same();
    }

    /**
     * On the actor's turn, as Pekko restarts it: restart (with its supervisor's leave) or stop,
     * then tell monitors and links, then the caller whose message crashed it.
     */
    private void restarting()
    {
      var cause = crashCause;
      long origin = crashOrigin;
      var reply = crashReply;
      var failure = crashFailure;
      crashReply = null;
      crashFailure = null;
      seen.add(origin);
      var parent = supervisor;
      boolean restarted =
          parent != null && restartState != null && parent.childCrashed(this, cause);
      if (!restarted)
      {
        halt();
      }
      for (var monitor : monitors)
      {
        monitor.accept(new Exit("crashed", cause));
      }
      for (var other : links)
      {
        other.linkCrash(cause, origin);
      }
      reply(reply, new Reply(null, failure));
    }

    private static void reply(ActorRef<Reply> to, Reply reply)
    {
      if (to != null)
      {
        to.tell(reply);
      }
    }

    /** On the actor's turn: the restarted state from the last one. */
    void restartNow()
    {
      state = restartState.apply(state);
    }

    /** A restart a supervisor asks of a sibling, in mailbox order. */
    void restartLater()
    {
      if (restartState == null)
      {
        return;
      }
      try
      {
        post(s -> new Next<Object, S>(null, restartState.apply(s)), null);
      }
      catch (ActorStopped e)
      {
        // already stopped
      }
    }

    private void linkCrash(Object cause, long origin)
    {
      if (seen.contains(origin))
      {
        return;
      }
      synchronized (lock)
      {
        if (stopped)
        {
          return;
        }
      }
      ref.tell(LawSpecCrashInterceptor.signal(cause, origin));
    }

    /** Stops the actor; messages still waiting fail with ActorStopped. */
    void halt()
    {
      synchronized (lock)
      {
        stopped = true;
        halted = true;
      }
      ref.tell(Ending.CHECK);
    }

    void setSupervisor(LawSpecPekkoSupervisor parent)
    {
      supervisor = parent;
    }

    @SuppressWarnings("unchecked")
    private void post(Function<S, ? extends Next<?, S>> handler, ActorRef<Reply> replyTo)
    {
      count();
      ref.tell(new Call((Function<Object, ? extends Next<?, Object>>) (Function<?, ?>) handler,
          replyTo));
    }

    private void count()
    {
      synchronized (lock)
      {
        if (stopped)
        {
          throw new ActorStopped("the actor has stopped");
        }
        pending++;
      }
    }

    /**
     * Runs the handler on the state in turn and returns its reply. A handler that throws crashes
     * the actor, and call throws ActorCrashed; a stopped actor throws ActorStopped.
     */
    @SuppressWarnings("unchecked")
    public <R> R call(Function<S, Next<R, S>> handler)
    {
      count();
      Reply reply = ask(ref, replyTo -> new Call(
          (Function<Object, ? extends Next<?, Object>>) (Function<?, ?>) handler, replyTo));
      if (reply.failure() != null)
      {
        throw reply.failure();
      }
      return (R) reply.value();
    }

    /** Queues the handler without waiting for its reply. */
    public void cast(Function<S, ? extends Next<?, S>> handler)
    {
      post(handler, null);
    }

    /**
     * Crashes the actor once the messages before this one are handled, as a failing handler would:
     * for testing supervision.
     */
    public void crash()
    {
      crash("crashed on purpose");
    }

    public void crash(Object cause)
    {
      synchronized (lock)
      {
        if (stopped)
        {
          throw new ActorStopped("the actor has stopped");
        }
      }
      ref.tell(LawSpecCrashInterceptor.signal(cause));
      try
      {
        call(s -> new Next<Object, S>(null, s));
      }
      catch (ActorStopped e)
      {
        // the crash stopped it
      }
    }

    /**
     * Replaces the state by restart(last state) between messages, as a supervised restart does
     * (crash injection in model runs).
     */
    public void restart(Function<S, S> restart)
    {
      call(s -> new Next<Object, S>(null, restart.apply(s)));
    }

    /** The state after every message sent before this call. */
    public S state()
    {
      return call(s -> new Next<S, S>(s, s));
    }

    /** notify gets Exit("crashed", cause) after each crash, and Exit("stopped", null) once. */
    public void monitor(Consumer<Exit> notify)
    {
      monitors.add(notify);
    }

    /** Links two actors: when either crashes, the other crashes too. */
    public void link(Actor<?> other)
    {
      links.add(other);
      other.links.add(this);
    }

    /**
     * Refuses further messages; those already queued still run. A permanent child of a supervisor
     * restarts instead.
     */
    public void stop()
    {
      var parent = supervisor;
      if (parent != null && parent.childStopped(this))
      {
        return;
      }
      boolean already;
      synchronized (lock)
      {
        already = stopped;
        stopped = true;
      }
      if (!already)
      {
        ref.tell(Ending.CHECK);
        for (var monitor : monitors)
        {
          monitor.accept(new Exit("stopped", null));
        }
      }
    }
  }

  /** A handler's failure, as the Pekko supervisor sees it. */
  private static final class HandlerFailed extends RuntimeException
  {
    HandlerFailed(Throwable cause)
    {
      super(null, cause, false, false);
    }
  }
}
