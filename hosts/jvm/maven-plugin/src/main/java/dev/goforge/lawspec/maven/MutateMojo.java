package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/** Runs the mutants against the tests: {@code lawspec mutate}. */
@Mojo(name = "mutate", threadSafe = true)
public class MutateMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.mutate.skip", defaultValue = "false")
  private boolean skipGoal;

  /** The mutant files or directories; the project's without them. */
  @Parameter(property = "lawspec.mutate.paths")
  private List<String> paths;

  /** Passes {@code --mutation-timeout} in milliseconds. */
  @Parameter(property = "lawspec.mutate.mutationTimeout")
  private Integer mutationTimeout;

  @Override
  protected boolean skipGoal()
  {
    return skipGoal;
  }

  @Override
  protected List<String> command()
  {
    List<String> line = new ArrayList<>();
    line.add("mutate");
    all(line, paths);
    option(line, "--mutation-timeout", mutationTimeout);
    return line;
  }
}
