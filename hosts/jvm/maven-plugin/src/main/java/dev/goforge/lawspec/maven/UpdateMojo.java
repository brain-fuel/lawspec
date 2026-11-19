package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/** Updates the project's packages: {@code lawspec update}. */
@Mojo(name = "update", threadSafe = true)
public class UpdateMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.update.skip", defaultValue = "false")
  private boolean skipGoal;

  /** The package to update; every package without it. */
  @Parameter(property = "lawspec.update.package")
  private String packageName;

  @Override
  protected boolean skipGoal()
  {
    return skipGoal;
  }

  @Override
  protected List<String> command()
  {
    List<String> line = new ArrayList<>();
    line.add("update");
    if (packageName != null)
    {
      line.add(packageName);
    }
    return line;
  }
}
