package dev.goforge.lawspec.maven;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class GeneratedDirectoriesTest
{
  @TempDir
  Path root;

  // The members of lawspec describe --json that the directories come from.
  private String describe(String targets)
  {
    return """
        {"format": "lawspec-component", "root": "%s", "targets": %s}
        """.formatted(root, targets);
  }

  /**
   * The generated source and test directories are read from the targets lawspec describe
   * reports, so the build compiles what generate writes.
   * ref:REQ-jvm-host ref:DEC-jvm-native-host
   */
  @Test
  void readsAJavaTargetsGeneratedDirectories()
  {
    GeneratedDirectories directories = GeneratedDirectories.of(describe("""
        [{"language": "java", "root": ".",
          "generatedSourceDir": "target/generated-sources/lawspec",
          "generatedTestDir": "target/generated-test-sources/lawspec"}]
        """), root, null);
    assertEquals(List.of(root.resolve("target/generated-sources/lawspec")), directories.sources());
    assertEquals(List.of(root.resolve("target/generated-test-sources/lawspec")),
        directories.tests());
  }

  /**
   * A target without generated directories adds none, since it generates into src/main and
   * src/test, which Maven already compiles.
   * ref:REQ-jvm-host ref:DEC-jvm-native-host
   */
  @Test
  void addsNothingForATargetThatGeneratesIntoTheSourceDirectories()
  {
    GeneratedDirectories directories = GeneratedDirectories
        .of(describe("[{\"language\": \"kotlin\", \"root\": \".\"}]"), root, null);
    assertEquals(List.of(), directories.sources());
    assertEquals(List.of(), directories.tests());
  }

  /**
   * Only the targets rooted at this project's directory and of the chosen language
   * contribute directories, so a module does not compile another's output.
   * ref:REQ-jvm-host ref:DEC-jvm-native-host
   */
  @Test
  void takesOnlyTheTargetsOfThisProjectAndTheChosenLanguage() throws IOException
  {
    Path service = Files.createDirectories(root.resolve("service"));
    String targets = """
        [{"language": "java", "root": "service", "generatedSourceDir": "target/java"},
         {"language": "java", "root": ".", "generatedSourceDir": "target/main"},
         {"language": "kotlin", "root": "."}]
        """;
    assertEquals(List.of(service.resolve("target/java")),
        GeneratedDirectories.of(describe(targets), service, null).sources());
    assertEquals(List.of(root.resolve("target/main")),
        GeneratedDirectories.of(describe(targets), root, null).sources());
    assertEquals(List.of(), GeneratedDirectories.of(describe(targets), root, "kotlin").sources());
  }
}
