package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/** Formats the specifications: {@code lawspec fmt}. */
@Mojo(name = "fmt", threadSafe = true)
public class FmtMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.fmt.skip", defaultValue = "false")
  private boolean skipGoal;

  /** The paths to format; the project's without them. */
  @Parameter(property = "lawspec.fmt.paths")
  private List<String> paths;

  /** Passes {@code --check}: fails if a file is not formatted, writing nothing. */
  @Parameter(property = "lawspec.fmt.check", defaultValue = "false")
  private boolean check;

  /** Passes {@code --compile}. */
  @Parameter(property = "lawspec.fmt.compile", defaultValue = "false")
  private boolean compile;

  @Override
  protected boolean skipGoal()
  {
    return skipGoal;
  }

  @Override
  protected List<String> command()
  {
    List<String> line = new ArrayList<>();
    line.add("fmt");
    all(line, paths);
    flag(line, "--check", check);
    flag(line, "--compile", compile);
    return line;
  }
}
