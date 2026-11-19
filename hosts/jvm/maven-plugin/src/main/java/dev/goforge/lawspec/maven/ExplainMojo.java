package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/** Explains the laws: {@code lawspec explain}. */
@Mojo(name = "explain", threadSafe = true)
public class ExplainMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.explain.skip", defaultValue = "false")
  private boolean skipGoal;

  /** The law to explain, as {@code <unit>::<law>}; every law without it. */
  @Parameter(property = "lawspec.explain.law")
  private String law;

  /** Passes {@code --view}: {@code eng}, {@code math} or {@code dev}. */
  @Parameter(property = "lawspec.explain.view")
  private String view;

  @Override
  protected boolean skipGoal()
  {
    return skipGoal;
  }

  @Override
  protected List<String> command()
  {
    List<String> line = new ArrayList<>();
    line.add("explain");
    if (law != null)
    {
      line.add(law);
    }
    option(line, "--view", view);
    return line;
  }
}
