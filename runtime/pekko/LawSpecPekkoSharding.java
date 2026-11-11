package lawspec.pekko;

import com.typesafe.config.ConfigFactory;
import java.time.Duration;
import java.util.function.Function;
import org.apache.pekko.actor.testkit.typed.javadsl.ActorTestKit;
import org.apache.pekko.actor.typed.Behavior;
import org.apache.pekko.actor.typed.RecipientRef;
import org.apache.pekko.cluster.MemberStatus;
import org.apache.pekko.cluster.sharding.typed.javadsl.ClusterSharding;
import org.apache.pekko.cluster.sharding.typed.javadsl.Entity;
import org.apache.pekko.cluster.sharding.typed.javadsl.EntityTypeKey;
import org.apache.pekko.cluster.typed.Cluster;
import org.apache.pekko.cluster.typed.Join;

/**
 * Sharded entities for LawSpecPekkoNative: a one-node Pekko Cluster in the test kit, where each
 * bound entity type runs under Cluster Sharding and every message goes through the entity's
 * EntityRef, as the application's own callers would send it. The entity type is named after the
 * application's EntityTypeKey; LawSpec starts it with the bound behaviour wrapped in its crash
 * interceptor, so the application's own sharding setup is not run.
 *
 * <p>
 * Each run's entities are its own: their ids carry the run, and the behaviour's factory gets the id
 * without it. ref:DEC-pekko-sample-suites
 */
public final class LawSpecPekkoSharding implements LawSpecPekkoNative.Entities
{
  private final String name;
  private EntityTypeKey<Object> key;

  private LawSpecPekkoSharding(String name)
  {
    this.name = name;
  }

  /** The entities of the application's entity type. */
  public static LawSpecPekkoSharding of(EntityTypeKey<?> key)
  {
    return new LawSpecPekkoSharding(key.name());
  }

  /** The entities of the application's entity type, as the Scala DSL names it. */
  public static LawSpecPekkoSharding of(
      org.apache.pekko.cluster.sharding.typed.scaladsl.EntityTypeKey<?> key)
  {
    return new LawSpecPekkoSharding(key.name());
  }

  @Override
  public ActorTestKit testKit()
  {
    return Node.KIT;
  }

  @Override
  public synchronized RecipientRef<Object> entity(String entityId,
      Function<String, Behavior<Object>> behavior)
  {
    var sharding = ClusterSharding.get(Node.KIT.system());
    if (key == null)
    {
      key = EntityTypeKey.create(Object.class, "lawspec-" + name);
      sharding.init(Entity.of(key, context -> behavior.apply(context.getEntityId())));
    }
    return sharding.entityRefFor(key, entityId);
  }

  /** The one-node cluster: it joins itself and is up before any entity starts. */
  private static final class Node
  {
    static final ActorTestKit KIT = joined();

    private static ActorTestKit joined()
    {
      var kit = ActorTestKit.create("lawspec-native-cluster",
          ConfigFactory.parseString(String.join("\n", "pekko.actor.provider = cluster",
              "pekko.remote.artery.canonical.port = 0",
              "pekko.remote.artery.canonical.hostname = 127.0.0.1", "pekko.cluster.seed-nodes = []",
              "pekko.cluster.jmx.multi-mbeans-in-same-jvm = on"))
              .withFallback(LawSpecPekkoNative.quiet()).withFallback(ConfigFactory.load()));
      Runtime.getRuntime().addShutdownHook(new Thread(kit::shutdownTestKit));
      var cluster = Cluster.get(kit.system());
      cluster.manager().tell(Join.create(cluster.selfMember().address()));
      long deadline = System.nanoTime() + Duration.ofSeconds(20).toNanos();
      while (cluster.selfMember().status() != MemberStatus.up())
      {
        if (System.nanoTime() > deadline)
        {
          throw new IllegalStateException("the one-node cluster did not come up within 20 s");
        }
        try
        {
          Thread.sleep(20);
        }
        catch (InterruptedException error)
        {
          Thread.currentThread().interrupt();
          throw new IllegalStateException("interrupted starting the one-node cluster", error);
        }
      }
      return kit;
    }
  }
}
