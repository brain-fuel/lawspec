package lawspec.pekko;

import io.github.seonwkim.actor.AskCommand;
import io.github.seonwkim.actor.EnableActorSupport;
import io.github.seonwkim.actor.SpringActor;
import io.github.seonwkim.actor.SpringActorContext;
import io.github.seonwkim.actor.internal.PekkoActorRef;
import io.github.seonwkim.actor.internal.PekkoBehaviors;
import java.util.HashMap;
import java.util.Map;
import java.util.function.Function;
import org.apache.pekko.actor.typed.ActorRef;
import org.apache.pekko.actor.typed.Behavior;
import org.springframework.boot.Banner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.SpringBootConfiguration;
import org.springframework.boot.WebApplicationType;
import org.springframework.context.ConfigurableApplicationContext;

/**
 * Checks an existing Spring starter actor (a SpringActor component) against a LawSpec actor's
 * model, through LawSpecPekkoNative. A Spring context holds the starter's actor support and the
 * bound component, so the component gets Spring's dependency injection; each run's actor is the
 * behaviour the component's create returns, compiled to Pekko by the starter's own compiler
 * (PekkoBehaviors), and runs unchanged in LawSpecPekkoNative's ActorTestKit with its crash
 * interceptor, its supervision strategy included. A handler's command is an AskCommand whose reply
 * address the check sets, as the starter's ask does. The component's other dependencies are not in
 * this context. ref:DEC-native-actor-binding ref:DEC-spring-actor-starter
 */
public final class LawSpecSpringNative
{
  private LawSpecSpringNative()
  {
  }

  /** The starter's actor support; the bound components join it. */
  @SpringBootConfiguration
  @EnableActorSupport
  public static class Support
  {
  }

  private static final Map<Class<?>, ConfigurableApplicationContext> CONTEXTS = new HashMap<>();

  /** The context an actor is created with: its id. */
  private static final class Context extends SpringActorContext
  {
    private final String id;

    Context(String id)
    {
      this.id = id;
    }

    @Override
    public String actorId()
    {
      return id;
    }
  }

  /**
   * A factory of the component's behaviour for an actor id, the run's actor identity, which each of
   * its restarts keeps.
   */
  public static <C> Function<String, Behavior<C>> behavior(
      Class<? extends SpringActor<C>> component)
  {
    return id -> {
      SpringActor<C> actor = context(component).getBean(component);
      return PekkoBehaviors.toPekko(actor.create(new Context(id)));
    };
  }

  /** command, answering to replyTo, as the starter's ask sends it. */
  public static <R, M extends AskCommand<R>> M asked(M command, ActorRef<R> replyTo)
  {
    command.withReplyTo(new PekkoActorRef<>(replyTo));
    return command;
  }

  private static synchronized ConfigurableApplicationContext context(Class<?> component)
  {
    return CONTEXTS.computeIfAbsent(component, type -> {
      var application = new SpringApplication(Support.class, type);
      application.setWebApplicationType(WebApplicationType.NONE);
      application.setBannerMode(Banner.Mode.OFF);
      application.setLogStartupInfo(false);
      application.setDefaultProperties(Map.<String, Object>of("logging.level.root", "WARN",
          "spring.actor.shutdown.exit-process", "false", "spring.actor.pekko.daemonic", "on",
          "spring.actor.pekko.loglevel", "OFF", "spring.actor.pekko.stdout-loglevel", "OFF"));
      return application.run();
    });
  }
}
