package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.LifecyclePhase;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/** Checks the specifications: {@code lawspec check}. Bound to {@code verify} by default. */
@Mojo(name = "check", defaultPhase = LifecyclePhase.VERIFY, threadSafe = true)
public class CheckMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.check.skip", defaultValue = "false")
  private boolean skipGoal;

  /** Passes {@code --warn-matches}. */
  @Parameter(property = "lawspec.check.warnMatches", defaultValue = "false")
  private boolean warnMatches;

  /** Passes {@code --no-advice}. */
  @Parameter(property = "lawspec.check.noAdvice", defaultValue = "false")
  private boolean noAdvice;

  @Override
  protected boolean skipGoal()
  {
    return skipGoal;
  }

  @Override
  protected List<String> command()
  {
    List<String> line = new ArrayList<>();
    line.add("check");
    flag(line, "--warn-matches", warnMatches);
    flag(line, "--no-advice", noAdvice);
    return line;
  }
}
