package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/** Fetches the project's packages: {@code lawspec fetch}. */
@Mojo(name = "fetch", threadSafe = true)
public class FetchMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.fetch.skip", defaultValue = "false")
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
    line.add("fetch");
    return line;
  }
}
