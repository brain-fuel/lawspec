package dev.goforge.lawspec.gradle;

import dev.goforge.lawspec.Installation;
import dev.goforge.lawspec.LawSpecException;
import java.io.File;
import java.util.ArrayList;
import java.util.List;
import javax.inject.Inject;
import org.gradle.api.DefaultTask;
import org.gradle.api.GradleException;
import org.gradle.api.file.ConfigurableFileCollection;
import org.gradle.api.file.DirectoryProperty;
import org.gradle.api.file.RegularFileProperty;
import org.gradle.api.provider.ListProperty;
import org.gradle.api.provider.MapProperty;
import org.gradle.api.provider.Property;
import org.gradle.api.tasks.Classpath;
import org.gradle.api.tasks.Input;
import org.gradle.api.tasks.Internal;
import org.gradle.api.tasks.Optional;
import org.gradle.api.tasks.TaskAction;
import org.gradle.api.tasks.options.Option;
import org.gradle.process.ExecOperations;

/**
 * Runs one lawspec command: the platform jar's binary, unpacked and verified by the launcher, in
 * the working directory. A command that exits with a code other than 0 fails the task. lawspec
 * keeps its own record of what it checked, generated and tested, so Gradle tracks no state for the
 * task and it always runs.
 */
public abstract class LawSpecTask extends DefaultTask
{
  /** Creates the task. */
  public LawSpecTask()
  {
    doNotTrackState("lawspec keeps its own cache of what it checked, generated and tested");
  }

  /**
   * The command and its own arguments, for example {@code check} or {@code project status}.
   *
   * @return the command
   */
  @Input
  public abstract ListProperty<String> getCommand();

  /**
   * Arguments appended after the command and the shared options. On the command line: {@code
   * --lawspec-args=--seed --lawspec-args=7}.
   *
   * @return the arguments
   */
  @Input
  @Option(option = "lawspec-args", description = "An argument to append to the lawspec command.")
  public abstract ListProperty<String> getArguments();

  /**
   * The project manifest, passed as {@code --config}.
   *
   * @return the manifest
   */
  @Internal
  public abstract RegularFileProperty getConfig();

  /**
   * The target language, passed as {@code --target}.
   *
   * @return the target
   */
  @Input
  @Optional
  public abstract Property<String> getTarget();

  /**
   * The directory lawspec runs in.
   *
   * @return the directory
   */
  @Internal
  public abstract DirectoryProperty getWorkingDirectory();

  /**
   * Environment variables to set, beside the inherited ones.
   *
   * @return the variables
   */
  @Input
  public abstract MapProperty<String, String> getEnvironment();

  /**
   * This platform's {@code dev.goforge:lawspec-<platform>} jar.
   *
   * @return the jar
   */
  @Classpath
  public abstract ConfigurableFileCollection getNativeJar();

  /**
   * The {@code dev.goforge:lawspec-resources} jar, which only {@code lawspecLearn} resolves.
   *
   * @return the jar, or nothing
   */
  @Classpath
  @Optional
  public abstract ConfigurableFileCollection getResourcesJar();

  /**
   * Gradle's process launcher.
   *
   * @return the exec operations
   */
  @Inject
  protected abstract ExecOperations getExecOperations();

  /** Runs the command. */
  @TaskAction
  public void run()
  {
    List<String> line = new ArrayList<>(getCommand().get());
    if (getConfig().isPresent())
    {
      line.add("--config");
      line.add(getConfig().get().getAsFile().getPath());
    }
    if (getTarget().isPresent())
    {
      line.add("--target");
      line.add(getTarget().get());
    }
    line.addAll(getArguments().get());
    Installation installation;
    try
    {
      File resources = getResourcesJar().isEmpty() ? null : getResourcesJar().getSingleFile();
      installation = Installation.of(getNativeJar().getSingleFile().toPath(),
          resources == null ? null : resources.toPath());
    }
    catch (LawSpecException e)
    {
      throw new GradleException(e.getMessage(), e);
    }
    File directory = getWorkingDirectory().get().getAsFile();
    int code = getExecOperations().exec(spec -> {
      spec.commandLine(installation.command(line));
      spec.workingDir(directory);
      spec.environment(installation.environment());
      spec.environment(getEnvironment().get());
      spec.setIgnoreExitValue(true);
    }).getExitValue();
    if (code != 0)
    {
      throw new GradleException("lawspec " + String.join(" ", line) + " exited with code " + code);
    }
  }
}
