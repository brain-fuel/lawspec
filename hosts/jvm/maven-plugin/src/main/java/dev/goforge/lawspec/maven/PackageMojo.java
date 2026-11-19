package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/** Packs a LawSpec package archive: {@code lawspec package}. */
@Mojo(name = "package", threadSafe = true)
public class PackageMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.package.skip", defaultValue = "false")
  private boolean skipGoal;

  /** Passes {@code --project}, the package directory. */
  @Parameter(property = "lawspec.package.project")
  private String packageProject;

  /** Passes {@code --output}, the archive to write. */
  @Parameter(property = "lawspec.package.output")
  private String output;

  @Override
  protected boolean skipGoal()
  {
    return skipGoal;
  }

  @Override
  protected List<String> command()
  {
    List<String> line = new ArrayList<>();
    line.add("package");
    option(line, "--project", packageProject);
    option(line, "--output", output);
    return line;
  }
}
