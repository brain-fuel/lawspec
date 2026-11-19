package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/** Checks the toolchains the targets need: {@code lawspec doctor}. */
@Mojo(name = "doctor", threadSafe = true)
public class DoctorMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.doctor.skip", defaultValue = "false")
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
    line.add("doctor");
    return line;
  }
}
