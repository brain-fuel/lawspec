package lawspec.runtime.pekko;

import java.util.ArrayList;
import java.util.List;
import lawspec.runtime.LawSpecRuntime.ActorCrashed;
import lawspec.runtime.LawSpecRuntime.ActorStopped;
import lawspec.runtime.LawSpecRuntime.Exit;
import lawspec.runtime.LawSpecRuntime.Next;

/**
 * OTP supervision for LawSpec actors on Pekko: the same strategies, lifetimes, restart limit and
 * escalation as LawSpecRuntime.Supervisor, over LawSpecPekko actors. Strategy "one_for_one"
 * restarts the child that crashed, "one_for_all" every child, "rest_for_one" it and those added
 * after it. A child's lifetime: "permanent" restarts after a crash or a stop, "transient" only
 * after a crash, "temporary" never. More than maxRestarts within period seconds is the
 * supervisor's own crash: its supervisor restarts all of its children, or, at the top, every
 * child stops, last added first, and its monitors are told.
 *
 * <p>
 * Pekko supervises each actor alone, and its restart limit stops only that actor, so the policy
 * across siblings is here. A child is a Pekko actor whose own restart strategy keeps its reference
 * and its waiting messages; on Pekko's PreRestart signal it asks this supervisor whether, and how,
 * to restart, and a sibling's restart is a message in its mailbox. Generated supervisors start one
 * with their strategy and limit and add their children in order, with each child's lifetime.
 * checkSupervision runs the conformance check LawSpecRuntime.checkSupervision runs, against Pekko.
 * ref:DEC-pekko-otp-supervision ref:erlang-otp-supervisor-behaviour
 */
public final class LawSpecPekkoSupervisor
{
  public static final String ONE_FOR_ONE = "one_for_one";
  public static final String ONE_FOR_ALL = "one_for_all";
  public static final String REST_FOR_ONE = "rest_for_one";
  public static final String PERMANENT = "permanent";
  public static final String TRANSIENT = "transient";
  public static final String TEMPORARY = "temporary";

  private static final class Entry
  {
    final Object child;
    final String lifetime;

    Entry(Object child, String lifetime)
    {
      this.child = child;
      this.lifetime = lifetime;
    }
  }

  private final String strategy;
  private final int maxRestarts;
  private final long periodNanos;
  private List<Entry> children = new ArrayList<>();
  private final java.util.ArrayDeque<Long> restarts = new java.util.ArrayDeque<>();
  private volatile LawSpecPekkoSupervisor supervisor;
  private boolean stopped;
  private final List<java.util.function.Consumer<Exit>> monitors =
      new java.util.concurrent.CopyOnWriteArrayList<>();

  public LawSpecPekkoSupervisor()
  {
    this(ONE_FOR_ONE, 3, 5.0);
  }

  public LawSpecPekkoSupervisor(String strategy)
  {
    this(strategy, 3, 5.0);
  }

  public LawSpecPekkoSupervisor(String strategy, int maxRestarts, double periodSeconds)
  {
    if (!List.of(ONE_FOR_ONE, ONE_FOR_ALL, REST_FOR_ONE).contains(strategy))
    {
      throw new IllegalArgumentException("unknown strategy " + strategy);
    }
    this.strategy = strategy;
    this.maxRestarts = maxRestarts;
    this.periodNanos = (long) (periodSeconds * 1e9);
  }

  /** Adds a started child (an Actor or a LawSpecPekkoSupervisor), and returns it. */
  public <C> C supervise(C child)
  {
    return supervise(child, PERMANENT);
  }

  public synchronized <C> C supervise(C child, String lifetime)
  {
    if (!List.of(PERMANENT, TRANSIENT, TEMPORARY).contains(lifetime))
    {
      throw new IllegalArgumentException("unknown lifetime " + lifetime);
    }
    setParent(child, this);
    children.add(new Entry(child, lifetime));
    return child;
  }

  public synchronized List<Object> children()
  {
    var out = new ArrayList<Object>();
    for (var e : children)
    {
      out.add(e.child);
    }
    return out;
  }

  /** How many restarts are counted in the current period (for the runtime's own check). */
  synchronized int restartCount()
  {
    return restarts.size();
  }

  private static void setParent(Object child, LawSpecPekkoSupervisor parent)
  {
    if (child instanceof LawSpecPekko.Actor<?> a)
    {
      a.setSupervisor(parent);
    }
    else if (child instanceof LawSpecPekkoSupervisor s)
    {
      s.supervisor = parent;
    }
    else
    {
      throw new IllegalArgumentException("a supervisor's child is an Actor or a LawSpecPekkoSupervisor");
    }
  }

  private static void restartLater(Object child)
  {
    if (child instanceof LawSpecPekko.Actor<?> a)
    {
      a.restartLater();
    }
    else
    {
      ((LawSpecPekkoSupervisor) child).restartLater();
    }
  }

  private static void halt(Object child)
  {
    if (child instanceof LawSpecPekko.Actor<?> a)
    {
      a.halt();
    }
    else
    {
      ((LawSpecPekkoSupervisor) child).stop();
    }
  }

  private static void stopChild(Object child)
  {
    if (child instanceof LawSpecPekko.Actor<?> a)
    {
      a.stop();
    }
    else
    {
      ((LawSpecPekkoSupervisor) child).stop();
    }
  }

  private boolean allowRestart()
  {
    long now = System.nanoTime();
    while (!restarts.isEmpty() && now - restarts.peekFirst() > periodNanos)
    {
      restarts.pollFirst();
    }
    if (restarts.size() >= maxRestarts)
    {
      return false;
    }
    restarts.addLast(now);
    return true;
  }

  private Entry entry(Object child)
  {
    for (var e : children)
    {
      if (e.child == child)
      {
        return e;
      }
    }
    return null;
  }

  /** Under the lock: the children to restart for entry's crash, or null when it gives up. */
  private List<Entry> restarting(Entry entry, Object cause, Object crashed)
  {
    if (allowRestart())
    {
      int index = children.indexOf(entry);
      return switch (strategy)
      {
        case ONE_FOR_ALL -> new ArrayList<>(children);
        case REST_FOR_ONE -> new ArrayList<>(children.subList(index, children.size()));
        default -> List.of(entry);
      };
    }
    var parent = supervisor;
    if (parent != null && parent.childFailed(this, cause))
    {
      restarts.clear();
      return new ArrayList<>(children);
    }
    fail(crashed, cause);
    return null;
  }

  /** On child's turn: true when it restarts now. */
  boolean childCrashed(LawSpecPekko.Actor<?> child, Object cause)
  {
    List<Entry> group;
    synchronized (this)
    {
      var entry = entry(child);
      if (stopped || entry == null)
      {
        return false;
      }
      if (entry.lifetime.equals(TEMPORARY))
      {
        children.remove(entry);
        return false;
      }
      group = restarting(entry, cause, child);
      if (group == null)
      {
        return false;
      }
    }
    for (var other : group)
    {
      if (other.child != child)
      {
        restartLater(other.child);
      }
    }
    child.restartNow();
    return true;
  }

  /** A child supervisor gave up: true when it may restart its children. */
  boolean childFailed(LawSpecPekkoSupervisor child, Object cause)
  {
    List<Entry> group;
    synchronized (this)
    {
      var entry = entry(child);
      if (stopped || entry == null)
      {
        return false;
      }
      if (entry.lifetime.equals(TEMPORARY))
      {
        children.remove(entry);
        return false;
      }
      group = restarting(entry, cause, child);
      if (group == null)
      {
        return false;
      }
    }
    for (var other : group)
    {
      if (other.child != child)
      {
        restartLater(other.child);
      }
    }
    return true;
  }

  /** True when a stopped child is permanent and restarts instead. */
  boolean childStopped(Object child)
  {
    List<Entry> group;
    synchronized (this)
    {
      var entry = entry(child);
      if (entry == null || stopped)
      {
        return false;
      }
      if (!entry.lifetime.equals(PERMANENT))
      {
        children.remove(entry);
        return false;
      }
      group = restarting(entry, "stopped", child);
      if (group == null)
      {
        return false;
      }
    }
    for (var other : group)
    {
      restartLater(other.child);
    }
    return true;
  }

  /**
   * Under the lock: every child but the crashing one (which stops itself) stops, and so does the
   * supervisor.
   */
  private void fail(Object crashed, Object cause)
  {
    var all = children;
    children = new ArrayList<>();
    stopped = true;
    for (int k = all.size() - 1; k >= 0; k--)
    {
      var other = all.get(k).child;
      setParent(other, null);
      if (other != crashed)
      {
        halt(other);
      }
    }
    for (var monitor : monitors)
    {
      monitor.accept(new Exit("crashed", cause));
    }
  }

  /** Restarted by its own supervisor: every child restarts. */
  private void restartLater()
  {
    List<Entry> all;
    synchronized (this)
    {
      restarts.clear();
      all = new ArrayList<>(children);
    }
    for (var e : all)
    {
      restartLater(e.child);
    }
  }

  /**
   * notify gets Exit("crashed", cause) when it passes its restart limit, and Exit("stopped",
   * null) once stopped.
   */
  public void monitor(java.util.function.Consumer<Exit> notify)
  {
    monitors.add(notify);
  }

  /** Stops every child, last added first, without restarting them. */
  public void stop()
  {
    List<Entry> all;
    synchronized (this)
    {
      if (stopped)
      {
        return;
      }
      stopped = true;
      all = children;
      children = new ArrayList<>();
    }
    for (int k = all.size() - 1; k >= 0; k--)
    {
      var child = all.get(k).child;
      setParent(child, null);
      stopChild(child);
    }
    for (var monitor : monitors)
    {
      monitor.accept(new Exit("stopped", null));
    }
  }


  /**
   * The runtime's own check of crashes, links, monitors and supervision on Pekko: every strategy,
   * lifetime, the restart limit and escalation, as LawSpecRuntime.checkSupervision checks them.
   * Throws AssertionError naming the first behaviour that differs.
   */
  public static void checkSupervision()
  {
    java.util.function.Supplier<LawSpecPekko.Actor<Long>> counter = () -> new LawSpecPekko.Actor<Long>(0L, s -> 0L);
    java.util.function.Consumer<LawSpecPekko.Actor<Long>> bump =
        a -> a.call(s -> new Next<Long, Long>(s + 1, s + 1));
    java.util.function.Consumer<LawSpecPekko.Actor<Long>> fail = a -> {
      try
      {
        a.call(s -> {
          throw new ArithmeticException("/ by zero");
        });
      }
      catch (ActorCrashed e)
      {
        return;
      }
      throw new AssertionError("a failing handler did not throw ActorCrashed");
    };
    java.util.function.BiConsumer<LawSpecPekko.Actor<Long>, String> stopped = (a, what) -> {
      try
      {
        a.state();
      }
      catch (ActorStopped e)
      {
        return;
      }
      throw new AssertionError(what + " should have stopped");
    };
    var a = counter.get();
    bump.accept(a);
    fail.accept(a);
    stopped.accept(a, "an unsupervised actor that crashed");
    var sup = new LawSpecPekkoSupervisor(LawSpecPekkoSupervisor.ONE_FOR_ONE);
    var x = sup.supervise(counter.get());
    var y = sup.supervise(counter.get());
    bump.accept(x);
    bump.accept(y);
    bump.accept(y);
    fail.accept(x);
    expectSupervision(List.of(x.state(), y.state()), List.of(0L, 2L),
        "one for one restarts only the crashed child");
    sup = new LawSpecPekkoSupervisor(LawSpecPekkoSupervisor.ONE_FOR_ALL);
    x = sup.supervise(counter.get());
    y = sup.supervise(counter.get());
    bump.accept(x);
    bump.accept(y);
    fail.accept(x);
    expectSupervision(List.of(x.state(), y.state()), List.of(0L, 0L),
        "one for all restarts every child");
    sup = new LawSpecPekkoSupervisor(LawSpecPekkoSupervisor.REST_FOR_ONE);
    x = sup.supervise(counter.get());
    y = sup.supervise(counter.get());
    var z = sup.supervise(counter.get());
    bump.accept(x);
    bump.accept(y);
    bump.accept(z);
    fail.accept(y);
    expectSupervision(List.of(x.state(), y.state(), z.state()), List.of(1L, 0L, 0L),
        "rest for one restarts the child and later ones");
    sup = new LawSpecPekkoSupervisor();
    var t = sup.supervise(counter.get(), LawSpecPekkoSupervisor.TEMPORARY);
    fail.accept(t);
    stopped.accept(t, "a temporary child that crashed");
    sup = new LawSpecPekkoSupervisor();
    var p = sup.supervise(counter.get(), LawSpecPekkoSupervisor.PERMANENT);
    var q = sup.supervise(counter.get(), LawSpecPekkoSupervisor.TRANSIENT);
    bump.accept(p);
    p.stop();
    expectSupervision(p.state(), 0L, "a permanent child restarts after a stop");
    q.stop();
    stopped.accept(q, "a transient child that was stopped");
    var events = new java.util.concurrent.CopyOnWriteArrayList<Exit>();
    sup = new LawSpecPekkoSupervisor(LawSpecPekkoSupervisor.ONE_FOR_ONE, 2, 10);
    sup.monitor(events::add);
    x = sup.supervise(counter.get());
    y = sup.supervise(counter.get());
    fail.accept(x);
    fail.accept(x);
    fail.accept(x);
    stopped.accept(y, "a child of a supervisor past its restart limit");
    expectSupervision(kinds(events), List.of("crashed"),
        "a supervisor past its limit tells its monitors");
    var outer = new LawSpecPekkoSupervisor(LawSpecPekkoSupervisor.ONE_FOR_ONE, 5, 10);
    var inner = outer.supervise(new LawSpecPekkoSupervisor(LawSpecPekkoSupervisor.ONE_FOR_ONE, 1, 10));
    x = inner.supervise(counter.get());
    y = inner.supervise(counter.get());
    bump.accept(y);
    fail.accept(x);
    fail.accept(x);
    expectSupervision(List.of(x.state(), y.state()), List.of(0L, 0L),
        "a supervisor past its limit is restarted by its own");
    var seen = new java.util.concurrent.CopyOnWriteArrayList<Exit>();
    a = counter.get();
    var b = counter.get();
    a.link(b);
    b.monitor(seen::add);
    fail.accept(a);
    for (int k = 0; k < 100 && seen.isEmpty(); k++)
    {
      sleepQuietly(10);
    }
    stopped.accept(b, "an unsupervised actor linked to one that crashed");
    expectSupervision(kinds(seen), List.of("crashed"), "a monitor hears of a crash");
    sup = new LawSpecPekkoSupervisor(LawSpecPekkoSupervisor.ONE_FOR_ONE, 10, 5.0);
    a = sup.supervise(counter.get());
    b = sup.supervise(counter.get());
    var c = sup.supervise(counter.get());
    a.link(b);
    b.link(c);
    c.link(a);
    bump.accept(a);
    bump.accept(b);
    bump.accept(c);
    fail.accept(a);
    for (int k = 0; k < 100 && sup.restartCount() < 3; k++)
    {
      sleepQuietly(10);
    }
    sleepQuietly(50);
    expectSupervision(List.of(a.state(), b.state(), c.state(), (long) sup.restartCount()),
        List.of(0L, 0L, 0L, 3L), "a crash crosses each link once");
  }

  private static List<String> kinds(List<Exit> exits)
  {
    var out = new ArrayList<String>();
    for (var e : exits)
    {
      out.add(e.kind());
    }
    return out;
  }

  private static void expectSupervision(Object actual, Object wanted, String what)
  {
    if (!actual.equals(wanted))
    {
      throw new AssertionError(what + ": got " + actual + ", expected " + wanted);
    }
  }

  private static void sleepQuietly(long millis)
  {
    try
    {
      Thread.sleep(millis);
    }
    catch (InterruptedException e)
    {
      Thread.currentThread().interrupt();
    }
  }
}
