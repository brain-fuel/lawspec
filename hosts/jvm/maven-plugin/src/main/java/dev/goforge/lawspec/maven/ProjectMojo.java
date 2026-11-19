package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/** Runs a Canon project command: {@code lawspec project init|adopt|status|validate}. */
@Mojo(name = "project", threadSafe = true)
public class ProjectMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.project.skip", defaultValue = "false")
  private boolean skipGoal;

  /** The project command: {@code init}, {@code adopt}, {@code status} or {@code validate}. */
  @Parameter(property = "lawspec.project.action", defaultValue = "status")
  private String action;

  /** Passes {@code --project}. */
  @Parameter(property = "lawspec.project.directory")
  private String projectDirectory;

  @Override
  protected boolean skipGoal()
  {
    return skipGoal;
  }

  @Override
  protected List<String> command()
  {
    List<String> line = new ArrayList<>();
    line.add("project");
    line.add(action);
    option(line, "--project", projectDirectory);
    return line;
  }
}
