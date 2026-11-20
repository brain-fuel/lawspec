package dev.goforge.lawspec.gradle;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import org.gradle.testkit.runner.BuildResult;
import org.gradle.testkit.runner.GradleRunner;
import org.gradle.testkit.runner.TaskOutcome;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * Builds a fixture project with the plugin under test. Its target is YAML, which generates with no
 * toolchain; the samples under hosts/jvm/samples build real Java and Kotlin targets. The platform
 * jar comes from the repository the {@code lawspec.repository} system property names, where
 * hosts/jvm installs it.
 */
class LawSpecPluginFunctionalTest
{
  private static final String LAW = """
      unit sample.laws

      law "|addition is commutative| is
        definition:
          for all (x of type Int32) (y of type Int32) =>
            x + y must be y + x
          end for all
        end definition
      end law
      end unit
      """;

  @TempDir
  Path project;

  @BeforeEach
  void writeProject() throws IOException
  {
    Files.writeString(project.resolve("settings.gradle.kts"), "rootProject.name = \"fixture\"\n");
    Files.writeString(project.resolve("lawspec.edn"), """
        {
          :manifest-version 1
          :component {:name "fixture" :version "0.1.0"}
          :language-profile "1.0-rc.2"
          :verification {:layers []}
          :sources ["laws"]
          :targets [{:language :yaml :root "generated"}]
        }
        """);
    Files.createDirectories(project.resolve("generated"));
    Files.createDirectories(project.resolve("laws"));
    Files.writeString(project.resolve("laws/sample.lawspec"), LAW);
    buildScript("");
  }

  private void buildScript(String extra) throws IOException
  {
    String repository = Path.of(System.getProperty("lawspec.repository")).toUri().toString();
    Files.writeString(project.resolve("build.gradle.kts"), """
        plugins {
          java
          id("dev.goforge.lawspec")
        }

        repositories {
          maven { url = uri("%s") }
          mavenCentral()
        }
        %s
        """.formatted(repository, extra));
  }

  private GradleRunner runner(String... arguments)
  {
    return GradleRunner.create().withProjectDir(project.toFile())
        .withTestKitDir(Path.of(System.getProperty("lawspec.testkit")).toFile())
        .withPluginClasspath().withArguments(List.of(arguments)).forwardOutput();
  }

  /**
   * The plugin registers a lawspec task for every command, so a Gradle build exposes
   * everything the CLI does.
   * ref:REQ-jvm-host ref:DEC-jvm-native-host
   */
  @Test
  void registersATaskForEveryCommand()
  {
    String output = runner("tasks", "--group", "lawspec").build().getOutput();
    for (String task : List.of("lawspecCheck", "lawspecGenerate", "lawspecTest", "lawspecProve",
        "lawspecExplain", "lawspecDoctor", "lawspecFmt", "lawspecMutate", "lawspecPackage",
        "lawspecEvidence", "lawspecAdvise", "lawspecInspect", "lawspecPrelude", "lawspecDescribe",
        "lawspecFetch", "lawspecUpdate", "lawspecExamples", "lawspecInit", "lawspecProjectStatus",
        "lawspecProjectValidate", "lawspecLearn"))
    {
      assertTrue(output.contains(task + " - Runs lawspec "), task);
    }
  }

  /**
   * By default generation runs before main compilation and check and test run with
   * the build's check, so a build needs no wiring by hand.
   * ref:REQ-jvm-host ref:DEC-jvm-native-host
   */
  @Test
  void wiresGenerationBeforeMainCompilationAndChecksIntoCheck()
  {
    String output = runner("check", "--dry-run").build().getOutput();
    int generate = output.indexOf(":lawspecGenerate SKIPPED");
    int compile = output.indexOf(":compileJava SKIPPED");
    assertTrue(generate >= 0 && compile > generate, output);
    assertTrue(output.contains(":lawspecCheck SKIPPED"), output);
    assertTrue(output.contains(":lawspecTest SKIPPED"), output);
  }

  /**
   * Each of the extension's four wiring switches turns its wiring off,
   * so a build can opt out of any one.
   * ref:REQ-jvm-host ref:DEC-jvm-native-host
   */
  @Test
  void switchesEachWiringOff() throws IOException
  {
    buildScript("""

        lawspec {
          generateBeforeMainCompile = false
          addSourceRoots = false
          checkOnCheck = false
          testOnCheck = false
        }
        """);
    String output = runner("check", "--dry-run").build().getOutput();
    assertFalse(output.contains(":lawspecGenerate"), output);
    assertFalse(output.contains(":lawspecCheck"), output);
    assertFalse(output.contains(":lawspecTest"), output);
  }

  /**
   * The directories lawspec generate writes into are compiled with the main sources and
   * found again under the configuration cache, so no source roots are added by hand.
   * ref:REQ-jvm-host ref:DEC-jvm-native-host
   */
  @Test
  void compilesTheGeneratedDirectoriesUnderTheConfigurationCache() throws IOException
  {
    javaTarget("");
    BuildResult first = runner("compileJava", "--configuration-cache").build();
    assertEquals(TaskOutcome.SUCCESS, first.task(":compileJava").getOutcome());
    assertTrue(
        Files.isRegularFile(project.resolve("build/classes/java/main/generated/Runtime.class")));
    BuildResult second = runner("compileJava", "--configuration-cache").build();
    assertTrue(second.getOutput().contains("Reusing configuration cache."), second.getOutput());
    assertEquals(TaskOutcome.UP_TO_DATE, second.task(":compileJava").getOutcome());
  }

  /**
   * With addSourceRoots off the generated directories are not added to the source sets,
   * so the build registers them itself.
   * ref:REQ-jvm-host ref:DEC-jvm-native-host
   */
  @Test
  void leavesTheSourceSetsAloneWhenSwitchedOff() throws IOException
  {
    javaTarget("  addSourceRoots = false\n");
    BuildResult result = runner("compileJava").build();
    assertEquals(TaskOutcome.NO_SOURCE, result.task(":compileJava").getOutcome());
  }

  // A Java target whose runtime is generated into a build directory, as a
  // Maven project's is. Generating a Java target runs Maven, so the fixture
  // writes the generated file itself and generation stays off.
  private void javaTarget(String settings) throws IOException
  {
    Files.writeString(project.resolve("lawspec.edn"), """
        {
          :manifest-version 1
          :component {:name "fixture" :version "0.1.0"}
          :language-profile "1.0-rc.2"
          :verification {:layers []}
          :sources ["laws"]
          :targets [{:language :java :root "."
                     :generated-source-dir "target/generated-sources/lawspec"
                     :generated-test-dir "target/generated-test-sources/lawspec"}]
        }
        """);
    Path generated =
        Files.createDirectories(project.resolve("target/generated-sources/lawspec/generated"));
    Files.writeString(generated.resolve("Runtime.java"),
        "package generated;\n\npublic final class Runtime\n{\n}\n");
    buildScript("""

        lawspec {
          generateBeforeMainCompile = false
        %s}
        """.formatted(settings));
  }

  /**
   * The tasks run the native binary and write its outputs, and a second run reuses the
   * configuration cache, so the plugin is compatible with it.
   * ref:REQ-jvm-host ref:DEC-jvm-native-host
   */
  @Test
  void runsLawspecAndReusesTheConfigurationCache()
  {
    BuildResult first = runner("lawspecCheck", "lawspecGenerate", "--configuration-cache").build();
    assertEquals(TaskOutcome.SUCCESS, first.task(":lawspecCheck").getOutcome());
    assertTrue(first.getOutput().contains("Compiled 1 law(s)."), first.getOutput());
    assertTrue(Files.isRegularFile(project.resolve("generated/configuration.yaml")));
    BuildResult second = runner("lawspecCheck", "lawspecGenerate", "--configuration-cache").build();
    assertTrue(second.getOutput().contains("Reusing configuration cache."), second.getOutput());
    assertEquals(TaskOutcome.SUCCESS, second.task(":lawspecCheck").getOutcome());
  }

  /**
   * The extension's config file and the task's arguments reach the command,
   * as the Maven plugin's do.
   * ref:REQ-jvm-host ref:DEC-jvm-native-host
   */
  @Test
  void passesTheConfigAndArguments() throws IOException
  {
    Files.move(project.resolve("lawspec.edn"), project.resolve("other.edn"));
    buildScript("""

        lawspec {
          config = file("other.edn")
        }
        """);
    BuildResult result =
        runner("lawspecExplain", "--lawspec-args=--view", "--lawspec-args=math").build();
    assertTrue(result.getOutput().contains("addition is commutative"), result.getOutput());
  }

  /**
   * A failing lawspec command fails the build with its exit code,
   * so a broken law cannot pass the build.
   * ref:REQ-jvm-host ref:DEC-jvm-native-host
   */
  @Test
  void failsTheBuildWhenLawspecFails() throws IOException
  {
    Files.writeString(project.resolve("laws/sample.lawspec"), LAW.replace("end unit", ""));
    BuildResult result = runner("lawspecCheck").buildAndFail();
    assertTrue(result.getOutput().contains("lawspec check exited with code 1"), result.getOutput());
  }
}
