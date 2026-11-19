package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/** Starts a LawSpec project for a target: {@code lawspec init}; set {@code target}. */
@Mojo(name = "init", requiresProject = false, threadSafe = true)
public class InitMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.init.skip", defaultValue = "false")
  private boolean skipGoal;

  /** Passes {@code --project}. */
  @Parameter(property = "lawspec.init.project")
  private String initProject;

  /** Passes {@code --name}. */
  @Parameter(property = "lawspec.init.name")
  private String name;

  /** Passes {@code --group}. */
  @Parameter(property = "lawspec.init.group")
  private String group;

  /** Passes {@code --release} (Java: 21 or 25). */
  @Parameter(property = "lawspec.init.release")
  private String release;

  /** Passes {@code --generated-source-dir}. */
  @Parameter(property = "lawspec.init.generatedSourceDir")
  private String generatedSourceDir;

  /** Passes {@code --generated-test-dir}. */
  @Parameter(property = "lawspec.init.generatedTestDir")
  private String generatedTestDir;

  /** Passes {@code --minify}. */
  @Parameter(property = "lawspec.init.minify", defaultValue = "false")
  private boolean minify;

  /** Passes {@code --no-install}. */
  @Parameter(property = "lawspec.init.noInstall", defaultValue = "false")
  private boolean noInstall;

  @Override
  protected boolean skipGoal()
  {
    return skipGoal;
  }

  @Override
  protected List<String> command()
  {
    List<String> line = new ArrayList<>();
    line.add("init");
    option(line, "--project", initProject);
    option(line, "--name", name);
    option(line, "--group", group);
    option(line, "--release", release);
    option(line, "--generated-source-dir", generatedSourceDir);
    option(line, "--generated-test-dir", generatedTestDir);
    flag(line, "--minify", minify);
    flag(line, "--no-install", noInstall);
    return line;
  }
}
