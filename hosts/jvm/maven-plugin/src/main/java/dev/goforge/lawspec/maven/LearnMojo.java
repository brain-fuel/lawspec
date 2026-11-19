package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/**
 * Serves the Learn LawSpec site on loopback until stopped: {@code lawspec learn}. It resolves
 * {@code dev.goforge:lawspec-resources} for the site.
 */
@Mojo(name = "learn", requiresProject = false, threadSafe = true)
public class LearnMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.learn.skip", defaultValue = "false")
  private boolean skipGoal;

  /** Passes {@code --port}. */
  @Parameter(property = "lawspec.learn.port")
  private Integer port;

  @Override
  protected boolean skipGoal()
  {
    return skipGoal;
  }

  @Override
  protected boolean needsResources()
  {
    return true;
  }

  @Override
  protected List<String> command()
  {
    List<String> line = new ArrayList<>();
    line.add("learn");
    option(line, "--port", port);
    return line;
  }
}
