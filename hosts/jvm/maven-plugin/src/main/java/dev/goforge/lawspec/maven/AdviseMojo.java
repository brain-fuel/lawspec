package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/** Gives authoring advice: {@code lawspec advise}. */
@Mojo(name = "advise", threadSafe = true)
public class AdviseMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.advise.skip", defaultValue = "false")
  private boolean skipGoal;

  /** Passes {@code --strict}: unresolved advice fails. */
  @Parameter(property = "lawspec.advise.strict", defaultValue = "false")
  private boolean strict;

  @Override
  protected boolean skipGoal()
  {
    return skipGoal;
  }

  @Override
  protected List<String> command()
  {
    List<String> line = new ArrayList<>();
    line.add("advise");
    flag(line, "--strict", strict);
    return line;
  }
}
