package lawspec.runtime.spring;

import io.github.seonwkim.actor.EnableActorSupport;
import io.github.seonwkim.actor.SpringActor;
import io.github.seonwkim.actor.SpringActorBehavior;
import io.github.seonwkim.actor.SpringActorContext;
import io.github.seonwkim.actor.SpringActorSystem;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Function;
import lawspec.runtime.pekko.LawSpecPekko;
import lawspec.runtime.pekko.LawSpecPekkoSupervisor;
import org.apache.pekko.actor.typed.ActorRef;
import org.apache.pekko.actor.typed.ActorSystem;
import org.apache.pekko.actor.typed.Behavior;
import org.springframework.boot.Banner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.SpringBootConfiguration;
import org.springframework.boot.WebApplicationType;
import org.springframework.context.annotation.ComponentScan;

/**
 * LawSpec actors on Apache Pekko through the Spring Boot actor starter
 * (io.github.seonwkim:actor-spring-boot-starter). Each generated actor class has a SpringActor
 * component, and its start spawns the LawSpec actor through the starter's SpringActorSystem as that
 * component's actor. The actor's behaviour is LawSpecPekko's, so its state, its restarts in place
 * and its supervision by LawSpecPekkoSupervisor (OTP's strategies, lifetimes, restart limit and
 * escalation) are the same as on :runtime :pekko, and every ask, supervisor and crash runs in the
 * starter's Pekko actor system.
 *
 * <p>
 * The actor system is the one given to use (an @ActorTest's, or the application's), or else one
 * this class starts on first use: a Spring context with only the starter's actor support and the
 * actor components in lawspec.actors, as the starter's @ActorTest slice starts, quiet and on daemon
 * threads. ref:DEC-spring-actor-starter ref:DEC-pekko-otp-supervision
 */
public final class LawSpecSpring
{
  private LawSpecSpring()
  {
  }

  /** The Spring application of LawSpec's actors: the starter's actor system and the actors. */
  @SpringBootConfiguration
  @EnableActorSupport
  @ComponentScan("lawspec.actors")
  public static class Actors
  {
  }

  private static SpringActorSystem system;

  private static final AtomicLong IDS = new AtomicLong();

  /**
   * The starter's actor system later actors run in: the one given to use, or else one started on
   * first use.
   */
  public static synchronized SpringActorSystem system()
  {
    if (system == null)
    {
      var application = new SpringApplication(Actors.class);
      application.setWebApplicationType(WebApplicationType.NONE);
      application.setBannerMode(Banner.Mode.OFF);
      application.setLogStartupInfo(false);
      application.setDefaultProperties(
          Map.<String, Object>of("logging.level.root", "WARN", "spring.actor.shutdown.exit-process",
              "false", "spring.actor.pekko.daemonic", "on", "spring.actor.pekko.loglevel", "OFF",
              "spring.actor.pekko.stdout-loglevel", "OFF", "spring.actor.pekko.log-dead-letters",
              "off", "spring.actor.pekko.log-dead-letters-during-shutdown", "off"));
      use(application.run().getBean(SpringActorSystem.class));
    }
    return system;
  }

  /** Runs later actors, asks and supervisors in the given starter's actor system. */
  public static synchronized void use(SpringActorSystem given)
  {
    system = given;
    LawSpecPekko.use(given.unwrap(ActorSystem.class));
  }

  /** The context a generated actor component is spawned with: its id and its behaviour. */
  public static final class Context extends SpringActorContext
  {
    private final String id;
    private final Behavior<Object> behavior;

    Context(String id, Behavior<Object> behavior)
    {
      this.id = id;
      this.behavior = behavior;
    }

    @Override
    public String actorId()
    {
      return id;
    }
  }

  /** What a generated actor component's create returns: the LawSpec actor's Pekko behaviour. */
  public static SpringActorBehavior<Object> behavior(SpringActorContext context)
  {
    if (!(context instanceof Context lawspec))
    {
      throw new IllegalArgumentException(
          "a LawSpec actor component is spawned by its actor class's start, not directly");
    }
    return SpringActorBehavior.wrap(lawspec.behavior);
  }

  /** A LawSpec actor of state, run as component's actor in the starter's actor system. */
  public static <S, A extends SpringActor<Object>> LawSpecPekko.Actor<S> actor(Class<A> component,
      S state, Function<S, S> restart)
  {
    return new LawSpecPekko.Actor<>(state, restart, behavior -> spawn(component, behavior));
  }

  @SuppressWarnings("unchecked")
  private static <A extends SpringActor<Object>> ActorRef<Object> spawn(Class<A> component,
      Behavior<Object> behavior)
  {
    var id = "lawspec-" + IDS.incrementAndGet();
    var handle =
        system().actor(component).withId(id).withContext(new Context(id, behavior)).spawnAndWait();
    return handle.unwrap(ActorRef.class);
  }

  /**
   * The conformance check of LawSpecPekkoSupervisor's OTP supervision, in the starter's actor
   * system.
   */
  public static void checkSupervision()
  {
    system();
    LawSpecPekkoSupervisor.checkSupervision();
  }

  /** The same check in the given actor system, such as an @ActorTest's. */
  public static void checkSupervision(SpringActorSystem given)
  {
    use(given);
    LawSpecPekkoSupervisor.checkSupervision();
  }
}
