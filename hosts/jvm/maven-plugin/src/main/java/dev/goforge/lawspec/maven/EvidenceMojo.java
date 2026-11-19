package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/** Reports the evidence for the laws: {@code lawspec evidence}. */
@Mojo(name = "evidence", threadSafe = true)
public class EvidenceMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.evidence.skip", defaultValue = "false")
  private boolean skipGoal;

  /** A unit, or {@code <unit>::<declaration>}; every unit without it. */
  @Parameter(property = "lawspec.evidence.subject")
  private String subject;

  /** Passes {@code --attestation}. */
  @Parameter(property = "lawspec.evidence.attestation")
  private String attestation;

  @Override
  protected boolean skipGoal()
  {
    return skipGoal;
  }

  @Override
  protected List<String> command()
  {
    List<String> line = new ArrayList<>();
    line.add("evidence");
    if (subject != null)
    {
      line.add(subject);
    }
    option(line, "--attestation", attestation);
    return line;
  }
}
