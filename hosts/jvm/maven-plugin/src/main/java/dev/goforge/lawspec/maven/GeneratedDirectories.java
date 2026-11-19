package dev.goforge.lawspec.maven;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.io.IOException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * The directories {@code lawspec generate} writes a project's generated code to, as the targets
 * that {@code lawspec describe --json} reports place it: a target's {@code generatedSourceDir} and
 * {@code generatedTestDir}, under its {@code root}, under the manifest's directory. A target
 * without them generates into its build's own source and test directories, which the build already
 * compiles. Only a target whose root is the project's directory counts, and only the one {@code
 * --target} names when it is given.
 *
 * @param sources the generated main-source directories
 * @param tests the generated test directories, which also hold generated test resources
 */
record GeneratedDirectories(List<Path> sources, List<Path> tests)
{
  /**
   * Reads the directories from a component document.
   *
   * @param describe the output of {@code lawspec describe --json}
   * @param project the project's directory
   * @param target the language {@code --target} names, or {@code null}
   * @return the directories
   */
  static GeneratedDirectories of(String describe, Path project, String target)
  {
    JsonObject component = JsonParser.parseString(describe).getAsJsonObject();
    Path root = Path.of(component.get("root").getAsString());
    List<Path> sources = new ArrayList<>();
    List<Path> tests = new ArrayList<>();
    for (JsonElement element : component.getAsJsonArray("targets"))
    {
      JsonObject entry = element.getAsJsonObject();
      if (target != null && !target.isEmpty() && !target.equals(text(entry, "language")))
      {
        continue;
      }
      String directory = text(entry, "root");
      Path targetRoot = root.resolve(directory == null ? "." : directory).normalize();
      if (!real(targetRoot).equals(real(project)))
      {
        continue;
      }
      add(sources, targetRoot, text(entry, "generatedSourceDir"));
      add(tests, targetRoot, text(entry, "generatedTestDir"));
    }
    return new GeneratedDirectories(List.copyOf(sources), List.copyOf(tests));
  }

  private static String text(JsonObject entry, String key)
  {
    JsonElement value = entry.get(key);
    return value != null && value.isJsonPrimitive() ? value.getAsString() : null;
  }

  private static void add(List<Path> directories, Path root, String directory)
  {
    if (directory != null && !directory.isEmpty())
    {
      Path path = root.resolve(directory).normalize();
      if (!directories.contains(path))
      {
        directories.add(path);
      }
    }
  }

  // lawspec runs in the real path of its working directory, which may name
  // the project's directory through a symbolic link.
  private static Path real(Path path)
  {
    try
    {
      return path.toRealPath();
    }
    catch (IOException e)
    {
      return path.toAbsolutePath().normalize();
    }
  }
}
