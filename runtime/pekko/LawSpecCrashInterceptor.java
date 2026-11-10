package lawspec.runtime.pekko;

import java.util.function.Predicate;
import org.apache.pekko.actor.typed.ActorRef;
import org.apache.pekko.actor.typed.Behavior;
import org.apache.pekko.actor.typed.BehaviorInterceptor;
import org.apache.pekko.actor.typed.TypedActorContext;
import org.apache.pekko.actor.typed.javadsl.Behaviors;

/**
 * Crash injection for Pekko Typed actors: a BehaviorInterceptor that passes every message to the
 * behaviour it wraps, except LawSpec's private crash signal, on which it throws InjectedCrash. The
 * wrapped behaviour's code does not change.
 *
 * <p>
 * The exception is thrown where the interceptor sits. Wrapped inside Behaviors.supervise, the
 * enclosing supervisor strategy handles it (a restart, resume or stop); wrapped outside every
 * supervisor, the actor fails and stops, and a watching parent gets ChildFailed. A message of any
 * other type reaches the wrapped behaviour unchanged. ref:DEC-pekko-runtime
 * ref:pekko-typed-interceptors
 */
public final class LawSpecCrashInterceptor<T> extends BehaviorInterceptor<Object, T>
{
  /** The private crash signal: made only by crash, so no application message can be one. */
  public static final class Crash
  {
    private final Object cause;
    private final long origin;

    private Crash(Object cause, long origin)
    {
      this.cause = cause;
      this.origin = origin;
    }

    /** Why the actor is crashed, as monitors hear it. */
    public Object cause()
    {
      return cause;
    }

    /** The first crash this one follows from, so a crash crosses each link once. */
    public long origin()
    {
      return origin;
    }
  }

  /** What the interceptor throws on the crash signal. */
  public static final class InjectedCrash extends RuntimeException
  {
    private final transient Crash crash;

    InjectedCrash(Crash crash)
    {
      super("crashed on purpose: " + crash.cause(), null, false, false);
      this.crash = crash;
    }

    public Crash crash()
    {
      return crash;
    }
  }

  private static final java.util.concurrent.atomic.AtomicLong ORIGINS =
      new java.util.concurrent.atomic.AtomicLong();

  private final Predicate<Crash> accept;

  /** Throws on every crash signal. */
  public LawSpecCrashInterceptor()
  {
    this(crash -> true);
  }

  /**
   * accept runs on the actor's turn before the throw; a crash it refuses (one that already reached
   * this actor through another link) is dropped.
   */
  public LawSpecCrashInterceptor(Predicate<Crash> accept)
  {
    super(Object.class);
    this.accept = accept;
  }

  /** behavior with crash injection; its reference takes the crash signal and T's messages. */
  public static <T> Behavior<Object> wrap(Behavior<T> behavior)
  {
    return Behaviors.intercept(LawSpecCrashInterceptor<T>::new, behavior);
  }

  /** A new crash signal with its own origin. */
  public static Crash signal(Object cause)
  {
    return new Crash(cause, ORIGINS.incrementAndGet());
  }

  /** The crash signal that follows from the crash origin names (across a link). */
  public static Crash signal(Object cause, long origin)
  {
    return new Crash(cause, origin);
  }

  /**
   * Crashes a wrapped actor once the messages sent to it before are handled, as a failing message
   * would.
   */
  public static void crash(ActorRef<Object> actor, Object cause)
  {
    actor.tell(signal(cause));
  }

  @Override
  @SuppressWarnings("unchecked")
  public Behavior<T> aroundReceive(TypedActorContext<Object> context, Object message,
      ReceiveTarget<T> target)
  {
    if (message instanceof Crash crash)
    {
      if (!accept.test(crash))
      {
        return Behaviors.same();
      }
      throw new InjectedCrash(crash);
    }
    return target.apply(context, (T) message);
  }
}
