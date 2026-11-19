package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/** Describes the compiler as JSON: {@code lawspec describe --json}. */
@Mojo(name = "describe", requiresProject = false, threadSafe = true)
public class DescribeMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.describe.skip", defaultValue = "false")
  private boolean skipGoal;

  @Override
  protected boolean skipGoal()
  {
    return skipGoal;
  }

  @Override
  protected List<String> command()
  {
    List<String> line = new ArrayList<>();
    line.add("describe");
    if (!json)
    {
      line.add("--json");
    }
    return line;
  }
}
