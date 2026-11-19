package dev.goforge.lawspec.gradle;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import dev.goforge.lawspec.Installation;
import dev.goforge.lawspec.LawSpecException;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import javax.inject.Inject;
import org.gradle.api.file.ConfigurableFileCollection;
import org.gradle.api.file.DirectoryProperty;
import org.gradle.api.file.RegularFileProperty;
import org.gradle.api.logging.Logger;
import org.gradle.api.logging.Logging;
import org.gradle.api.provider.MapProperty;
import org.gradle.api.provider.Property;
import org.gradle.api.provider.ValueSource;
import org.gradle.api.provider.ValueSourceParameters;
import org.gradle.process.ExecOperations;
import org.gradle.process.ExecResult;

/**
 * The directories {@code lawspec generate} writes the project's generated code to, as the targets
 * that {@code lawspec describe --json} reports place it: a target's {@code generatedSourceDir}
 * ({@link #SOURCES}) and {@code generatedTestDir} ({@link #TESTS}), under its {@code root}, under
 * the manifest's directory. A target without them generates into the build's own source
 * directories, which need no registering. Only a target whose root is the project's directory
 * counts, and only the one {@code target} names when it is set. When lawspec describe fails, there
 * are none: lawspecGenerate then fails with lawspec's own diagnostics.
 */
public abstract class GeneratedDirectories
    implements ValueSource<Map<String, List<String>>, GeneratedDirectories.Parameters>
{
  /** The key of the generated main-source directories. */
  public static final String SOURCES = "sources";

  /** The key of the generated test directories, which also hold generated test resources. */
  public static final String TESTS = "tests";

  private static final Logger LOGGER = Logging.getLogger(GeneratedDirectories.class);

  /** What lawspec describe runs with: the lawspec extension's settings. */
  public interface Parameters extends ValueSourceParameters
  {
    /**
     * This platform's {@code dev.goforge:lawspec-<platform>} jar.
     *
     * @return the jar
     */
    ConfigurableFileCollection getNativeJar();

    /**
     * The project manifest, passed as {@code --config}.
     *
     * @return the manifest
     */
    RegularFileProperty getConfig();

    /**
     * The directory lawspec runs in.
     *
     * @return the directory
     */
    DirectoryProperty getWorkingDirectory();

    /**
     * The project's directory, which a target's root must be.
     *
     * @return the directory
     */
    DirectoryProperty getProjectDirectory();

    /**
     * The target language, or none for every target.
     *
     * @return the target
     */
    Property<String> getTarget();

    /**
     * Environment variables to set, beside the inherited ones.
     *
     * @return the variables
     */
    MapProperty<String, String> getEnvironment();

    /**
     * Whether Gradle runs offline, which passes {@code --offline}.
     *
     * @return the switch
     */
    Property<Boolean> getOffline();
  }

  /** Creates the value source. */
  public GeneratedDirectories()
  {
  }

  /**
   * Gradle's process launcher.
   *
   * @return the exec operations
   */
  @Inject
  protected abstract ExecOperations getExecOperations();

  @Override
  public Map<String, List<String>> obtain()
  {
    Parameters parameters = getParameters();
    List<String> line = new ArrayList<>(List.of("describe", "--json"));
    if (parameters.getConfig().isPresent())
    {
      line.add("--config");
      line.add(parameters.getConfig().get().getAsFile().getPath());
    }
    if (parameters.getOffline().getOrElse(false))
    {
      line.add("--offline");
    }
    Installation installation;
    try
    {
      installation = Installation.of(parameters.getNativeJar().getSingleFile().toPath(), null);
    }
    catch (LawSpecException e)
    {
      LOGGER.info("lawspec: cannot read the generated directories: {}", e.getMessage());
      return empty();
    }
    ByteArrayOutputStream output = new ByteArrayOutputStream();
    ByteArrayOutputStream errors = new ByteArrayOutputStream();
    ExecResult result = getExecOperations().exec(spec -> {
      spec.commandLine(installation.command(line));
      spec.workingDir(parameters.getWorkingDirectory().get().getAsFile());
      spec.environment(installation.environment());
      spec.environment(parameters.getEnvironment().get());
      spec.setStandardOutput(output);
      spec.setErrorOutput(errors);
      spec.setIgnoreExitValue(true);
    });
    if (result.getExitValue() != 0)
    {
      LOGGER.info("lawspec: cannot read the generated directories: {}",
          errors.toString(StandardCharsets.UTF_8));
      return empty();
    }
    return read(output.toString(StandardCharsets.UTF_8),
        parameters.getProjectDirectory().get().getAsFile().toPath(),
        parameters.getTarget().getOrNull());
  }

  private static Map<String, List<String>> empty()
  {
    Map<String, List<String>> directories = new HashMap<>();
    directories.put(SOURCES, new ArrayList<>());
    directories.put(TESTS, new ArrayList<>());
    return directories;
  }

  // The directories of the targets in a component document.
  private static Map<String, List<String>> read(String describe, Path project, String target)
  {
    JsonObject component = JsonParser.parseString(describe).getAsJsonObject();
    Path root = Path.of(component.get("root").getAsString());
    Map<String, List<String>> directories = empty();
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
      add(directories.get(SOURCES), targetRoot, text(entry, "generatedSourceDir"));
      add(directories.get(TESTS), targetRoot, text(entry, "generatedTestDir"));
    }
    return directories;
  }

  private static String text(JsonObject entry, String key)
  {
    JsonElement value = entry.get(key);
    return value != null && value.isJsonPrimitive() ? value.getAsString() : null;
  }

  private static void add(List<String> directories, Path root, String directory)
  {
    if (directory != null && !directory.isEmpty())
    {
      String path = root.resolve(directory).normalize().toString();
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
