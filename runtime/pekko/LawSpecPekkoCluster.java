package lawspec.runtime.pekko;

import com.typesafe.config.Config;
import com.typesafe.config.ConfigFactory;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.NotSerializableException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicReference;
import lawspec.runtime.LawSpecRuntime;
import lawspec.runtime.LawSpecRuntime.ActorCrashed;
import lawspec.runtime.LawSpecRuntime.ActorStopped;
import lawspec.runtime.LawSpecRuntime.Served;
import lawspec.runtime.LawSpecRuntime.Signature;
import lawspec.runtime.LawSpecRuntime.Unreachable;
import lawspec.runtime.LawSpecRuntime.Value;
import lawspec.runtime.LawSpecRuntime.Values;
import org.apache.pekko.actor.CoordinatedShutdown;
import org.apache.pekko.actor.ExtendedActorSystem;
import org.apache.pekko.actor.typed.ActorRef;
import org.apache.pekko.actor.typed.ActorRefResolver;
import org.apache.pekko.actor.typed.ActorSystem;
import org.apache.pekko.actor.typed.Props;
import org.apache.pekko.actor.typed.javadsl.Adapter;
import org.apache.pekko.actor.typed.javadsl.AskPattern;
import org.apache.pekko.actor.typed.javadsl.Behaviors;
import org.apache.pekko.actor.typed.receptionist.Receptionist;
import org.apache.pekko.actor.typed.receptionist.ServiceKey;
import org.apache.pekko.cluster.Member;
import org.apache.pekko.cluster.MemberStatus;
import org.apache.pekko.cluster.typed.Cluster;
import org.apache.pekko.cluster.typed.Join;
import org.apache.pekko.serialization.SerializerWithStringManifest;

/**
 * LawSpec actors served and called across Pekko Cluster (lawspec.edn's
 * {@code :actors {:remote :cluster}}): a Node is a cluster member, serve registers an actor with
 * Pekko's typed Receptionist under its name, and remoteActor looks it up there and calls it over
 * Artery.
 *
 * <p>
 * Each served actor has one receiving actor per node and name, registered with the receptionist; it
 * decodes a call's arguments, runs the handler on the LawSpec actor and answers. Serving the name
 * again on the same node serves the new actor through the same registration. Values cross in
 * LawSpec's canonical wire encoding (LawSpecRuntime.wireEncode), carried by WireSerializer, a Pekko
 * serializer bound to the Call and Answer messages; Java serialization stays off.
 *
 * <p>
 * Failures are explicit: a call is not answered within its timeout, or its node is unreachable or
 * has left the cluster (Pekko Cluster's membership), throws Unreachable; a crashed or stopped actor
 * throws ActorCrashed or ActorStopped, as over LawSpec's own network. Pekko Cluster has no fault
 * injection like MemoryNetwork's, so partition and heal throw UnsupportedOperationException.
 * ref:DEC-pekko-cluster-remote ref:pekko-cluster-typed ref:pekko-serialization
 */
public final class LawSpecPekkoCluster
{
  private LawSpecPekkoCluster()
  {
  }

  private static final java.util.concurrent.atomic.AtomicLong SERVED =
      new java.util.concurrent.atomic.AtomicLong();

  /** The actor system name every node of a LawSpec cluster shares. */
  public static final String SYSTEM = "lawspec";

  /** The messages WireSerializer carries. */
  public interface Wire
  {
  }

  /**
   * A call: the handler's name, each argument in LawSpec's canonical wire encoding, and where the
   * answer goes.
   */
  public record Call(String message, List<byte[]> arguments,
      ActorRef<Answer> replyTo) implements Wire
  {
  }

  /**
   * A call's answer: status 0 with the reply in the canonical wire encoding, or 1 (the actor
   * crashed), 2 (it has stopped) or 3 (the call was refused) with a message, as LawSpec's own
   * network answers.
   */
  public record Answer(int status, byte[] body) implements Wire
  {
  }

  /**
   * The settings a node's actor system needs besides its own: the cluster provider, WireSerializer
   * for LawSpec's messages, and no Java serialization. An application's own cluster adds these to
   * its configuration to serve LawSpec actors (Node.of).
   */
  public static Config config()
  {
    return ConfigFactory.parseString(String.join("\n", "pekko.actor.provider = cluster",
        "pekko.actor.allow-java-serialization = off",
        "pekko.actor.serializers.lawspec-wire = \"" + WireSerializer.class.getName() + "\"",
        "pekko.actor.serialization-bindings {", "  \"" + Wire.class.getName() + "\" = lawspec-wire",
        "}"));
  }

  /**
   * A local test node's settings: on 127.0.0.1 at a free port, daemon threads, quiet logs, and
   * registrations spread quickly between nodes in one JVM.
   */
  private static Config local()
  {
    return ConfigFactory.parseString(String.join("\n", "pekko.daemonic = on",
        "pekko.loglevel = \"OFF\"", "pekko.stdout-loglevel = \"OFF\"",
        "pekko.log-dead-letters = off", "pekko.log-dead-letters-during-shutdown = off",
        "pekko.remote.artery.canonical.hostname = \"127.0.0.1\"",
        "pekko.remote.artery.canonical.port = 0", "pekko.cluster.seed-nodes = []",
        "pekko.cluster.jmx.multi-mbeans-in-same-jvm = on", "pekko.cluster.gossip-interval = 200ms",
        "pekko.cluster.typed.receptionist.distributed-data.gossip-interval = 200ms",
        "pekko.cluster.typed.receptionist.distributed-data.notify-subscribers-interval = 50ms",
        "pekko.coordinated-shutdown.exit-jvm = off")).withFallback(config())
        .withFallback(ConfigFactory.load());
  }

  /**
   * A member of a Pekko Cluster that serves LawSpec actors and calls those other members serve. Its
   * address is the member's, such as pekko://lawspec@127.0.0.1:52011, and a served actor's address
   * is the node's address, a slash and its name.
   */
  public static final class Node implements AutoCloseable
  {
    public final String address;
    private final ActorSystem<?> system;
    private final boolean owned;
    private final Map<String, Entry> served = new ConcurrentHashMap<>();
    private final ExecutorService workers = Executors.newVirtualThreadPerTaskExecutor();

    private Node(ActorSystem<?> system, boolean owned)
    {
      this.system = system;
      this.owned = owned;
      this.address = Cluster.get(system).selfMember().address().toString();
    }

    /** A new cluster on this machine whose first member is this node, on a free local port. */
    public static Node start()
    {
      var node = new Node(ActorSystem.create(Behaviors.<Void>empty(), SYSTEM, local()), true);
      node.joining(node.address);
      return node;
    }

    /** A new node on this machine, on a free local port, that joins the cluster of seed. */
    public static Node join(Node seed)
    {
      return join(seed.address);
    }

    /** A new node on this machine, on a free local port, that joins the member at seed. */
    public static Node join(String seed)
    {
      var node = new Node(ActorSystem.create(Behaviors.<Void>empty(), SYSTEM, local()), true);
      node.joining(seed);
      return node;
    }

    /**
     * The node of an application's own cluster member, whose configuration includes config();
     * closing it leaves the system running.
     */
    public static Node of(ActorSystem<?> system)
    {
      return new Node(system, false);
    }

    /** Joins the member at seed and waits until this node is up, at most 30 seconds. */
    private void joining(String seed)
    {
      var cluster = Cluster.get(system);
      cluster.manager().tell(Join.create(org.apache.pekko.actor.AddressFromURIString.parse(seed)));
      long deadline = System.nanoTime() + Duration.ofSeconds(30).toNanos();
      while (cluster.selfMember().status() != MemberStatus.up())
      {
        if (System.nanoTime() > deadline)
        {
          close();
          throw new Unreachable(address + " did not join the cluster at " + seed + " within 30s");
        }
        pause(20);
      }
    }

    /**
     * Lets other members call actor at {address}/name: handlers maps a message name to its handler
     * and types. Returns that address.
     */
    public <S> String serve(String name, LawSpecPekko.Actor<S> actor,
        Map<String, Served<S>> handlers, Values values)
    {
      var entry = served.computeIfAbsent(name, this::register);
      entry.target.set(new Target<>(actor, handlers, values));
      return address + "/" + name;
    }

    /** The receiving actor for name, registered with the receptionist. */
    private Entry register(String name)
    {
      var entry = new Entry();
      ActorRef<Call> ref =
          system.systemActorOf(Behaviors.receive(Call.class).onMessage(Call.class, call -> {
            workers.execute(() -> call.replyTo().tell(answer(entry.target.get(), call)));
            return Behaviors.same();
          }).build(), "lawspec-served-" + SERVED.incrementAndGet(), Props.empty());
      await(AskPattern.<Receptionist.Command, Receptionist.Registered>ask(system.receptionist(),
          replyTo -> Receptionist.register(key(name), ref, replyTo), Duration.ofSeconds(10),
          system.scheduler()), "registering " + name + " with the receptionist", 10);
      return entry;
    }

    /**
     * The actor served at address on another member (or this one); a call not answered within
     * timeout seconds, or whose member is unreachable or gone, throws Unreachable.
     */
    public RemoteActor remoteActor(String address, Map<String, Signature> signatures, Values values,
        double timeout)
    {
      int slash = address.lastIndexOf('/');
      String at = slash < 0 ? "" : address.substring(0, slash);
      String name = address.substring(slash + 1);
      long deadline = System.nanoTime() + (long) (timeout * 1e9);
      while (true)
      {
        Receptionist.Listing listing =
            await(AskPattern.<Receptionist.Command, Receptionist.Listing>ask(system.receptionist(),
                replyTo -> Receptionist.find(key(name), replyTo), Duration.ofSeconds(5),
                system.scheduler()), "looking up " + address + " with the receptionist", 10);
        for (ActorRef<Call> ref : listing.getServiceInstances(key(name)))
        {
          String member = memberOf(ref);
          if (at.isEmpty() || at.equals(member))
          {
            return new RemoteActor(this, address, member, ref, signatures, values, timeout);
          }
        }
        if (System.nanoTime() > deadline)
        {
          throw new Unreachable("no reachable actor is served at " + address + " (receptionist)");
        }
        pause(20);
      }
    }

    /** The member a reference lives on: this node's address for a local one. */
    private String memberOf(ActorRef<?> ref)
    {
      var where = ref.path().address();
      return where.hasLocalScope() ? address : where.toString();
    }

    /**
     * Whether the member at address is in the cluster and reachable: joining, up or leaving, and
     * not marked unreachable by the failure detector.
     */
    boolean reachable(String member)
    {
      if (member.equals(address))
      {
        return true;
      }
      var state = Cluster.get(system).state();
      for (Member unreachable : state.getUnreachable())
      {
        if (unreachable.address().toString().equals(member))
        {
          return false;
        }
      }
      for (Member each : state.getMembers())
      {
        if (each.address().toString().equals(member))
        {
          var status = each.status();
          return status == MemberStatus.up() || status == MemberStatus.weaklyUp()
              || status == MemberStatus.joining() || status == MemberStatus.leaving();
        }
      }
      return false;
    }

    /**
     * Pekko Cluster has no fault injection like MemoryNetwork's partition: always throws
     * UnsupportedOperationException.
     */
    public void partition(List<List<String>> groups)
    {
      throw new UnsupportedOperationException("partition is not supported on Pekko Cluster"
          + " (:remote :cluster): Pekko has no public way to cut members off; use a MemoryNetwork"
          + " with :remote omitted to test partitions");
    }

    /** Always throws UnsupportedOperationException, as partition does. */
    public void heal()
    {
      partition(List.of());
    }

    /**
     * Leaves the cluster and stops the node's actor system, waiting at most 30 seconds; the node's
     * port is then closed. A node of an application's system (Node.of) stops only its own actors.
     */
    @Override
    public void close()
    {
      workers.shutdownNow();
      if (!owned)
      {
        return;
      }
      CoordinatedShutdown.get(system).run(CoordinatedShutdown.unknownReason());
      try
      {
        system.getWhenTerminated().toCompletableFuture().get(30, TimeUnit.SECONDS);
      }
      catch (InterruptedException error)
      {
        Thread.currentThread().interrupt();
      }
      catch (ExecutionException | TimeoutException error)
      {
        system.terminate();
      }
    }

    ActorSystem<?> system()
    {
      return system;
    }
  }

  /** The receptionist key LawSpec actors are served under. */
  private static ServiceKey<Call> key(String name)
  {
    return ServiceKey.create(Call.class, "lawspec-actor:" + name);
  }

  /** What a node serves under one name: the latest actor served there. */
  private static final class Entry
  {
    final AtomicReference<Target<?>> target = new AtomicReference<>();
  }

  private record Target<S>(LawSpecPekko.Actor<S> actor, Map<String, Served<S>> handlers,
      Values values)
  {
  }

  /** Runs a call on the served actor, as LawSpec's own node does, and gives its answer. */
  private static <S> Answer answer(Target<S> target, Call call)
  {
    Served<S> served = target.handlers().get(call.message());
    List<Value> arguments = new ArrayList<>();
    try
    {
      if (served == null)
      {
        throw new IllegalArgumentException("no message " + call.message());
      }
      if (served.arguments().size() != call.arguments().size())
      {
        throw new IllegalArgumentException(
            "expected " + served.arguments().size() + " arguments, not " + call.arguments().size());
      }
      for (int i = 0; i < call.arguments().size(); i++)
      {
        arguments.add(LawSpecRuntime.wireDecode(target.values(), served.arguments().get(i),
            call.arguments().get(i)));
      }
    }
    catch (RuntimeException error)
    {
      return failed(3, "not a message this actor handles: " + error.getMessage());
    }
    try
    {
      Value result = target.actor().call(state -> served.handler().apply(state, arguments));
      return new Answer(0, LawSpecRuntime.wireEncode(target.values(), served.reply(), result));
    }
    catch (ActorCrashed error)
    {
      return failed(1, String.valueOf(error.getMessage()));
    }
    catch (ActorStopped error)
    {
      return failed(2, String.valueOf(error.getMessage()));
    }
    catch (RuntimeException error)
    {
      return failed(3, String.valueOf(error.getMessage()));
    }
  }

  private static Answer failed(int status, String message)
  {
    return new Answer(status, message.getBytes(StandardCharsets.UTF_8));
  }

  /**
   * Calls an actor served on a member: call(message, arguments) sends the message and waits for the
   * reply, throwing Unreachable after the timeout or as soon as the member is unreachable or has
   * left the cluster, or what the actor's call threw (ActorCrashed, ActorStopped).
   */
  public static final class RemoteActor
  {
    public final String address;
    private final Node node;
    private final String member;
    private final ActorRef<Call> ref;
    private final Map<String, Signature> signatures;
    private final Values values;
    private final double timeout;

    RemoteActor(Node node, String address, String member, ActorRef<Call> ref,
        Map<String, Signature> signatures, Values values, double timeout)
    {
      this.node = node;
      this.address = address;
      this.member = member;
      this.ref = ref;
      this.signatures = signatures;
      this.values = values;
      this.timeout = timeout;
    }

    public Value call(String message, List<Value> arguments)
    {
      var signature = signatures.get(message);
      var encoded = new ArrayList<byte[]>();
      for (int i = 0; i < signature.arguments().size(); i++)
      {
        encoded
            .add(LawSpecRuntime.wireEncode(values, signature.arguments().get(i), arguments.get(i)));
      }
      if (!node.reachable(member))
      {
        throw gone();
      }
      var pending = AskPattern
          .<Call, Answer>ask(ref, replyTo -> new Call(message, List.copyOf(encoded), replyTo),
              Duration.ofMillis((long) (timeout * 1000)), node.system().scheduler())
          .toCompletableFuture();
      Answer answer = waitFor(pending);
      var text = new String(answer.body(), StandardCharsets.UTF_8);
      return switch (answer.status())
      {
        case 0 -> LawSpecRuntime.wireDecode(values, signature.reply(), answer.body());
        case 1 -> throw new ActorCrashed(new IllegalStateException(text));
        case 2 -> throw new ActorStopped(text);
        default -> throw new Unreachable(text);
      };
    }

    /** The answer, watching the member's membership while waiting. */
    private Answer waitFor(CompletableFuture<Answer> pending)
    {
      while (true)
      {
        try
        {
          return pending.get(50, TimeUnit.MILLISECONDS);
        }
        catch (TimeoutException waiting)
        {
          if (!node.reachable(member))
          {
            throw gone();
          }
        }
        catch (ExecutionException error)
        {
          throw new Unreachable(address + " did not answer within " + timeout + "s");
        }
        catch (InterruptedException error)
        {
          Thread.currentThread().interrupt();
          throw new Unreachable("interrupted while waiting for " + address);
        }
      }
    }

    private Unreachable gone()
    {
      return new Unreachable(address + " is unreachable: its member " + member
          + " is unreachable or has left the" + " cluster");
    }
  }

  /**
   * Pekko's serializer for LawSpec's messages: a call's handler name, its arguments and its reply
   * address, or an answer's status and body. The arguments and replies are already in LawSpec's
   * canonical wire encoding; the reply address is written with Pekko's ActorRefResolver. Each field
   * is a length (four bytes, big-endian) and its bytes.
   */
  public static final class WireSerializer extends SerializerWithStringManifest
  {
    /** "LS" and 1: outside Pekko's reserved identifiers 0 to 40. */
    public static final int IDENTIFIER = 0x4C530001;

    private final ExtendedActorSystem system;
    private volatile ActorRefResolver resolver;

    public WireSerializer(ExtendedActorSystem system)
    {
      this.system = system;
    }

    private ActorRefResolver resolver()
    {
      if (resolver == null)
      {
        resolver = ActorRefResolver.get(Adapter.toTyped(system));
      }
      return resolver;
    }

    @Override
    public int identifier()
    {
      return IDENTIFIER;
    }

    @Override
    public String manifest(Object message)
    {
      if (message instanceof Call)
      {
        return "call";
      }
      if (message instanceof Answer)
      {
        return "answer";
      }
      throw new IllegalArgumentException("not a LawSpec message: " + message.getClass());
    }

    @Override
    public byte[] toBinary(Object message)
    {
      var bytes = new ByteArrayOutputStream();
      try (var out = new DataOutputStream(bytes))
      {
        if (message instanceof Call call)
        {
          field(out, call.message().getBytes(StandardCharsets.UTF_8));
          field(out,
              resolver().toSerializationFormat(call.replyTo()).getBytes(StandardCharsets.UTF_8));
          out.writeInt(call.arguments().size());
          for (var argument : call.arguments())
          {
            field(out, argument);
          }
        }
        else if (message instanceof Answer answer)
        {
          out.writeInt(answer.status());
          field(out, answer.body());
        }
        else
        {
          throw new IllegalArgumentException("not a LawSpec message: " + message.getClass());
        }
      }
      catch (IOException error)
      {
        throw new UncheckedIOException(error);
      }
      return bytes.toByteArray();
    }

    @Override
    public Object fromBinary(byte[] bytes, String manifest) throws NotSerializableException
    {
      try (var in = new DataInputStream(new ByteArrayInputStream(bytes)))
      {
        switch (manifest)
        {
          case "call":
            String message = new String(field(in), StandardCharsets.UTF_8);
            ActorRef<Answer> replyTo =
                resolver().resolveActorRef(new String(field(in), StandardCharsets.UTF_8));
            int count = in.readInt();
            var arguments = new ArrayList<byte[]>();
            for (int i = 0; i < count; i++)
            {
              arguments.add(field(in));
            }
            return new Call(message, List.copyOf(arguments), replyTo);
          case "answer":
            int status = in.readInt();
            return new Answer(status, field(in));
          default:
            throw new NotSerializableException("not a LawSpec message: " + manifest);
        }
      }
      catch (IOException error)
      {
        var failure = new NotSerializableException("a malformed LawSpec " + manifest);
        failure.initCause(error);
        throw failure;
      }
    }

    private static void field(DataOutputStream out, byte[] bytes) throws IOException
    {
      out.writeInt(bytes.length);
      out.write(bytes);
    }

    private static byte[] field(DataInputStream in) throws IOException
    {
      int length = in.readInt();
      if (length < 0 || length > in.available())
      {
        throw new IOException("a field longer than the message");
      }
      return in.readNBytes(length);
    }
  }

  /** The value of a future, or Unreachable naming what did not happen within seconds. */
  private static <T> T await(java.util.concurrent.CompletionStage<T> pending, String what,
      long seconds)
  {
    try
    {
      return pending.toCompletableFuture().get(seconds, TimeUnit.SECONDS);
    }
    catch (TimeoutException | ExecutionException error)
    {
      throw new Unreachable(what + " did not finish within " + seconds + "s");
    }
    catch (InterruptedException error)
    {
      Thread.currentThread().interrupt();
      throw new Unreachable("interrupted while " + what);
    }
  }

  private static void pause(long millis)
  {
    try
    {
      Thread.sleep(millis);
    }
    catch (InterruptedException error)
    {
      Thread.currentThread().interrupt();
      throw new Unreachable("interrupted while waiting for the cluster");
    }
  }
}
