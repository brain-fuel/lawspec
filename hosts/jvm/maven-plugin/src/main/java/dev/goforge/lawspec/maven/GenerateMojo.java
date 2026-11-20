package dev.goforge.lawspec.maven;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import org.apache.maven.model.Resource;
import org.apache.maven.plugin.MojoExecutionException;
import org.apache.maven.plugin.MojoFailureException;
import org.apache.maven.plugins.annotations.LifecyclePhase;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/**
 * Generates the targets' code: {@code lawspec generate}. Bound to {@code generate-sources} by
 * default, so it runs before main compilation. It then adds the directories lawspec generates into
 * to the build, as {@code lawspec describe --json} reports the targets: a target's {@code
 * :generated-source-dir} as a compile source root, and its {@code :generated-test-dir} as a test
 * compile source root and a test resource directory (for the files that are not Java). A target
 * without them generates into the build's own source directories.
 */
@Mojo(name = "generate", defaultPhase = LifecyclePhase.GENERATE_SOURCES, threadSafe = true)
public class GenerateMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.generate.skip", defaultValue = "false")
  private boolean skipGoal;

  /** Passes {@code --dry-run}. */
  @Parameter(property = "lawspec.generate.dryRun", defaultValue = "false")
  private boolean dryRun;

  /** Passes {@code --check}: fails if a generated file is stale, writing nothing. */
  @Parameter(property = "lawspec.generate.check", defaultValue = "false")
  private boolean check;

  /** Passes {@code --minify}. */
  @Parameter(property = "lawspec.generate.minify", defaultValue = "false")
  private boolean minify;

  /** Passes {@code --no-advice}. */
  @Parameter(property = "lawspec.generate.noAdvice", defaultValue = "false")
  private boolean noAdvice;

  /**
   * Adds the target's generated directories to the build. Off, the build registers them itself.
   */
  @Parameter(property = "lawspec.generate.addSourceRoots", defaultValue = "true")
  private boolean addSourceRoots;

  /**
   * Generates, then adds the target's generated directories to the build as source roots and
   * test resources, unless the goal is skipped or {@code addSourceRoots} is off.
   */
  @Override
  public void execute() throws MojoExecutionException, MojoFailureException
  {
    super.execute();
    if (skipped() || !addSourceRoots)
    {
      return;
    }
    GeneratedDirectories directories;
    try
    {
      directories = GeneratedDirectories.of(output(List.of("describe", "--json")),
          project.getBasedir().toPath(), target);
    }
    catch (RuntimeException e)
    {
      throw new MojoExecutionException("Cannot read the targets lawspec describe reports", e);
    }
    for (Path directory : directories.sources())
    {
      getLog().debug("Adding the compile source root " + directory);
      project.addCompileSourceRoot(directory.toString());
    }
    for (Path directory : directories.tests())
    {
      getLog().debug("Adding the test compile source root " + directory);
      project.addTestCompileSourceRoot(directory.toString());
      if (project.getTestResources().stream()
          .noneMatch(resource -> directory.toString().equals(resource.getDirectory())))
      {
        Resource resource = new Resource();
        resource.setDirectory(directory.toString());
        resource.addExclude("**/*.java");
        project.addTestResource(resource);
      }
    }
  }

  @Override
  protected boolean skipGoal()
  {
    return skipGoal;
  }

  @Override
  protected List<String> command()
  {
    List<String> line = new ArrayList<>();
    line.add("generate");
    flag(line, "--dry-run", dryRun);
    flag(line, "--check", check);
    flag(line, "--minify", minify);
    flag(line, "--no-advice", noAdvice);
    return line;
  }
}
