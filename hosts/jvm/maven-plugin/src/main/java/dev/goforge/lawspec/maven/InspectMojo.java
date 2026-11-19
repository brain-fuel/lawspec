package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/** Shows a target's generated and bound interfaces: {@code lawspec inspect}; set {@code target}. */
@Mojo(name = "inspect", threadSafe = true)
public class InspectMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.inspect.skip", defaultValue = "false")
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
    line.add("inspect");
    return line;
  }
}
