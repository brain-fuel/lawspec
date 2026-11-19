package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/**
 * Runs lawspec with the {@code arguments} given, for a command without a goal of its own
 * ({@code lsp}, {@code mcp}): {@code mvn lawspec:run -Dlawspec.arguments=lsp,--stdio}.
 */
@Mojo(name = "run", requiresProject = false, threadSafe = true)
public class RunMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.run.skip", defaultValue = "false")
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

    return line;
  }
}
