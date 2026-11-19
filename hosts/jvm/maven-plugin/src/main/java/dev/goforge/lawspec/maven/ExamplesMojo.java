package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/** Writes the bundled example projects: {@code lawspec examples}. */
@Mojo(name = "examples", requiresProject = false, threadSafe = true)
public class ExamplesMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.examples.skip", defaultValue = "false")
  private boolean skipGoal;

  /** Passes {@code --example}. */
  @Parameter(property = "lawspec.examples.example")
  private String example;

  /** Passes {@code --output}, the directory to write. */
  @Parameter(property = "lawspec.examples.output")
  private String output;

  /** Passes {@code --minify}. */
  @Parameter(property = "lawspec.examples.minify", defaultValue = "false")
  private boolean minify;

  @Override
  protected boolean skipGoal()
  {
    return skipGoal;
  }

  @Override
  protected List<String> command()
  {
    List<String> line = new ArrayList<>();
    line.add("examples");
    option(line, "--example", example);
    option(line, "--output", output);
    flag(line, "--minify", minify);
    return line;
  }
}
