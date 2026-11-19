package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/** Proves the laws with a solver: {@code lawspec prove}. */
@Mojo(name = "prove", threadSafe = true)
public class ProveMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.prove.skip", defaultValue = "false")
  private boolean skipGoal;

  /** Passes {@code --solver}, the Z3 executable. */
  @Parameter(property = "lawspec.prove.solver")
  private String solver;

  /** Passes {@code --proof-timeout} in milliseconds. */
  @Parameter(property = "lawspec.prove.proofTimeout")
  private Integer proofTimeout;

  @Override
  protected boolean skipGoal()
  {
    return skipGoal;
  }

  @Override
  protected List<String> command()
  {
    List<String> line = new ArrayList<>();
    line.add("prove");
    option(line, "--solver", solver);
    option(line, "--proof-timeout", proofTimeout);
    return line;
  }
}
