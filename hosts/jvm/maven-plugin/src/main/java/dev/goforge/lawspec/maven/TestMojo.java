package dev.goforge.lawspec.maven;

import java.util.ArrayList;
import java.util.List;
import org.apache.maven.plugins.annotations.LifecyclePhase;
import org.apache.maven.plugins.annotations.Mojo;
import org.apache.maven.plugins.annotations.Parameter;

/**
 * Runs the laws' tests in each target: {@code lawspec test}. Bound to {@code verify} by default;
 * {@code -DskipTests} and {@code -Dmaven.test.skip} skip it too.
 */
@Mojo(name = "test", defaultPhase = LifecyclePhase.VERIFY, threadSafe = true)
public class TestMojo extends AbstractLawSpecMojo
{
  /** Skips this goal. */
  @Parameter(property = "lawspec.test.skip", defaultValue = "false")
  private boolean skipGoal;

  /** Passes {@code --fresh}. */
  @Parameter(property = "lawspec.test.fresh", defaultValue = "false")
  private boolean fresh;

  /** Passes {@code --seed}. */
  @Parameter(property = "lawspec.test.seed")
  private Long seed;

  /** Passes {@code --attestation}. */
  @Parameter(property = "lawspec.test.attestation")
  private String attestation;

  /** Passes {@code --update-recorded}. */
  @Parameter(property = "lawspec.test.updateRecorded", defaultValue = "false")
  private boolean updateRecorded;

  /** Passes {@code --tag} for each. */
  @Parameter(property = "lawspec.test.tags")
  private List<String> tags;

  /** Passes {@code --exclude-tag} for each. */
  @Parameter(property = "lawspec.test.excludeTags")
  private List<String> excludeTags;

  /** Passes {@code --report} for each, for example {@code junit=target/lawspec.xml}. */
  @Parameter(property = "lawspec.test.reports")
  private List<String> reports;

  /** Passes {@code --coverage}. */
  @Parameter(property = "lawspec.test.coverage", defaultValue = "false")
  private boolean coverage;

  /** Passes {@code --benchmarks}. */
  @Parameter(property = "lawspec.test.benchmarks", defaultValue = "false")
  private boolean benchmarks;

  /** Maven's {@code skipTests}. */
  @Parameter(property = "skipTests", defaultValue = "false")
  private boolean skipTests;

  /** Maven's {@code maven.test.skip}. */
  @Parameter(property = "maven.test.skip", defaultValue = "false")
  private boolean skipMavenTests;

  @Override
  protected boolean skipGoal()
  {
    return skipGoal || skipTests || skipMavenTests;
  }

  @Override
  protected List<String> command()
  {
    List<String> line = new ArrayList<>();
    line.add("test");
    flag(line, "--fresh", fresh);
    option(line, "--seed", seed);
    option(line, "--attestation", attestation);
    flag(line, "--update-recorded", updateRecorded);
    options(line, "--tag", tags);
    options(line, "--exclude-tag", excludeTags);
    options(line, "--report", reports);
    flag(line, "--coverage", coverage);
    flag(line, "--benchmarks", benchmarks);
    return line;
  }
}
