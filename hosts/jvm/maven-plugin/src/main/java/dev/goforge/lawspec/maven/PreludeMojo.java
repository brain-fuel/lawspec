package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/** Searches the prelude: {@code lawspec prelude}. */
@Mojo(name = "prelude", requiresProject = false, threadSafe = true)
public class PreludeMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.prelude.skip", defaultValue = "false")
  private boolean skipGoal;

  /** What to search for; everything without it. */
  @Parameter(property = "lawspec.prelude.query")
  private String query;

  @Override
  protected boolean skipGoal()
  {
    return skipGoal;
  }

  @Override
  protected List<String> command()
  {
    List<String> line = new ArrayList<>();
    line.add("prelude");
    if (query != null)
    {
      line.add(query);
    }
    return line;
  }
}
