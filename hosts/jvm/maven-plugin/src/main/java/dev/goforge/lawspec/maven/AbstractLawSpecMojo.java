package dev.goforge.lawspec.maven;

import dev.goforge.lawspec.Installation;
import dev.goforge.lawspec.LawSpecException;
import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import javax.inject.Inject;
import org.apache.maven.execution.MavenSession;
import org.apache.maven.plugin.AbstractMojo;
import org.apache.maven.plugin.MojoExecutionException;
import org.apache.maven.plugin.MojoFailureException;
import org.apache.maven.plugins.annotations.Parameter;
import org.apache.maven.project.MavenProject;
import org.eclipse.aether.RepositorySystem;
import org.eclipse.aether.artifact.DefaultArtifact;
import org.eclipse.aether.resolution.ArtifactRequest;
import org.eclipse.aether.resolution.ArtifactResolutionException;

/**
 * A goal that runs one lawspec command. It resolves this platform's {@code
 * dev.goforge:lawspec-<platform>} jar of the plugin's version from the plugin repositories, has the
 * launcher unpack and verify its binary, and runs the binary in {@link #workingDirectory} with the
 * standard streams of Maven. A command that exits with a code other than 0 fails the build. The
 * goal builds the command line from its parameters and nothing else: what the command does is the
 * binary's.
 */
public abstract class AbstractLawSpecMojo extends AbstractMojo
{
  @Parameter(defaultValue = "${project}", readonly = true, required = true)
  protected MavenProject project;

  @Parameter(defaultValue = "${session}", readonly = true, required = true)
  protected MavenSession session;

  /** Skips every LawSpec goal. */
  @Parameter(property = "lawspec.skip", defaultValue = "false")
  protected boolean skip;

  /**
   * The project manifest, passed as {@code --config}; lawspec finds {@code lawspec.edn} without it.
   */
  @Parameter(property = "lawspec.config")
  protected File config;

  /** The directory lawspec runs in. */
  @Parameter(property = "lawspec.workingDirectory", defaultValue = "${project.basedir}")
  protected File workingDirectory;

  /** The target language, passed as {@code --target}. */
  @Parameter(property = "lawspec.target")
  protected String target;

  /** The machine profile, 32 or 64, passed as {@code --machine-bits}. */
  @Parameter(property = "lawspec.machineBits")
  protected Integer machineBits;

  /** Passes {@code --json}. */
  @Parameter(property = "lawspec.json", defaultValue = "false")
  protected boolean json;

  /** Passes {@code --no-cache}. */
  @Parameter(property = "lawspec.noCache", defaultValue = "false")
  protected boolean noCache;

  /** Passes {@code --timings}. */
  @Parameter(property = "lawspec.timings", defaultValue = "false")
  protected boolean timings;

  /** Passes {@code --locked}. */
  @Parameter(property = "lawspec.locked", defaultValue = "false")
  protected boolean locked;

  /** Passes {@code --offline}; Maven's own offline mode ({@code -o}) sets it. */
  @Parameter(property = "lawspec.offline", defaultValue = "${settings.offline}")
  protected boolean offline;

  /** More arguments, appended as given. */
  @Parameter(property = "lawspec.arguments")
  protected List<String> arguments;

  /** Environment variables to set for lawspec, beside the inherited ones. */
  @Parameter
  protected Map<String, String> environment;

  /** A platform jar to use instead of resolving one. */
  @Parameter(property = "lawspec.nativeJar")
  protected File nativeJar;

  @Inject
  protected RepositorySystem repositorySystem;

  /**
   * Returns the command and its own arguments, without the shared options.
   *
   * @return the command line after {@code lawspec}
   */
  protected abstract List<String> command();

  /**
   * Returns whether this goal's own skip parameter is set.
   *
   * @return whether to skip
   */
  protected boolean skipGoal()
  {
    return false;
  }

  /**
   * Returns whether this goal needs the resources jar ({@code lawspec learn}).
   *
   * @return whether to resolve it
   */
  protected boolean needsResources()
  {
    return false;
  }

  /**
   * Runs the goal's command with the shared options and the standard streams passed through,
   * unless the goal is skipped.
   */
  @Override
  public void execute() throws MojoExecutionException, MojoFailureException
  {
    List<String> command = command();
    if (skipped())
    {
      getLog().info("Skipping lawspec " + String.join(" ", command));
      return;
    }
    List<String> line = new ArrayList<>(command);
    option(line, "--config", config == null ? null : config.getPath());
    option(line, "--target", target);
    option(line, "--machine-bits", machineBits);
    flag(line, "--json", json);
    flag(line, "--no-cache", noCache);
    flag(line, "--timings", timings);
    flag(line, "--locked", locked);
    flag(line, "--offline", offline);
    if (arguments != null)
    {
      line.addAll(arguments);
    }
    Installation installation = installation();
    run(installation, process(installation, line).inheritIO(), line);
  }

  /**
   * Returns whether this goal is skipped.
   *
   * @return whether {@link #skip} or the goal's own skip parameter is set
   */
  protected boolean skipped()
  {
    return skip || skipGoal();
  }

  /**
   * Runs a lawspec command that reads the project, with {@code --config}, {@code --locked} and
   * {@code --offline} when they are set, and returns what it writes to standard output; standard
   * error goes to Maven's.
   *
   * @param command the command and its own arguments
   * @return the standard output
   * @throws MojoExecutionException if lawspec cannot run
   * @throws MojoFailureException if lawspec exits with a code other than 0
   */
  protected String output(List<String> command) throws MojoExecutionException, MojoFailureException
  {
    List<String> line = new ArrayList<>(command);
    option(line, "--config", config == null ? null : config.getPath());
    flag(line, "--locked", locked);
    flag(line, "--offline", offline);
    Installation installation = installation();
    ProcessBuilder builder =
        process(installation, line).redirectInput(ProcessBuilder.Redirect.INHERIT)
            .redirectError(ProcessBuilder.Redirect.INHERIT);
    return run(installation, builder, line);
  }

  private ProcessBuilder process(Installation installation, List<String> line)
  {
    ProcessBuilder builder =
        new ProcessBuilder(installation.command(line)).directory(workingDirectory);
    builder.environment().putAll(installation.environment());
    if (environment != null)
    {
      builder.environment().putAll(environment);
    }
    return builder;
  }

  // Runs lawspec and returns its standard output, which is empty when the
  // process writes it to Maven's own.
  private String run(Installation installation, ProcessBuilder builder, List<String> line)
      throws MojoExecutionException, MojoFailureException
  {
    getLog().debug("Running " + builder.command());
    String output;
    int code;
    try
    {
      Process process = builder.start();
      try
      {
        output = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
        code = process.waitFor();
      }
      catch (InterruptedException e)
      {
        process.destroy();
        Thread.currentThread().interrupt();
        throw new MojoExecutionException("Interrupted while lawspec ran", e);
      }
    }
    catch (IOException e)
    {
      throw new MojoExecutionException("Cannot run " + installation.binary(), e);
    }
    if (code != 0)
    {
      throw new MojoFailureException(
          "lawspec " + String.join(" ", line) + " exited with code " + code);
    }
    return output;
  }

  private Installation installation() throws MojoExecutionException
  {
    try
    {
      Path platformJar =
          nativeJar != null ? nativeJar.toPath() : resolve(Installation.platformCoordinates());
      Path resourcesJar = needsResources() ? resolve(Installation.resourcesCoordinates()) : null;
      return Installation.of(platformJar, resourcesJar);
    }
    catch (LawSpecException e)
    {
      throw new MojoExecutionException(e.getMessage(), e);
    }
  }

  private Path resolve(String coordinates) throws MojoExecutionException
  {
    ArtifactRequest request = new ArtifactRequest(new DefaultArtifact(coordinates),
        project.getRemotePluginRepositories(), null);
    try
    {
      return repositorySystem.resolveArtifact(session.getRepositorySession(), request).getArtifact()
          .getFile().toPath();
    }
    catch (ArtifactResolutionException e)
    {
      throw new MojoExecutionException("Cannot resolve " + coordinates
          + ", the LawSpec binary for this platform: " + e.getMessage(), e);
    }
  }

  /**
   * Appends a flag when it is set.
   *
   * @param line the command line
   * @param name the flag
   * @param set whether it is set
   */
  protected static void flag(List<String> line, String name, boolean set)
  {
    if (set)
    {
      line.add(name);
    }
  }

  /**
   * Appends an option and its value when the value is given.
   *
   * @param line the command line
   * @param name the option
   * @param value its value, or {@code null}
   */
  protected static void option(List<String> line, String name, Object value)
  {
    if (value != null && !value.toString().isEmpty())
    {
      line.add(name);
      line.add(value.toString());
    }
  }

  /**
   * Appends an option once for each value.
   *
   * @param line the command line
   * @param name the option
   * @param values its values, or {@code null}
   */
  protected static void options(List<String> line, String name, List<String> values)
  {
    if (values != null)
    {
      for (String value : values)
      {
        option(line, name, value);
      }
    }
  }

  /**
   * Appends each value as an argument.
   *
   * @param line the command line
   * @param values the values, or {@code null}
   */
  protected static void all(List<String> line, List<String> values)
  {
    if (values != null)
    {
      line.addAll(values);
    }
  }
}
