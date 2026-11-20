package dev.goforge.lawspec.gradle;

import dev.goforge.lawspec.Platform;
import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import org.gradle.api.Plugin;
import org.gradle.api.Project;
import org.gradle.api.Task;
import org.gradle.api.artifacts.Configuration;
import org.gradle.api.artifacts.dsl.DependencyFactory;
import org.gradle.api.file.ConfigurableFileCollection;
import org.gradle.api.plugins.JavaPlugin;
import org.gradle.api.provider.Provider;
import org.gradle.api.provider.ProviderFactory;
import org.gradle.api.tasks.Copy;
import org.gradle.api.tasks.SourceSet;
import org.gradle.api.tasks.SourceSetContainer;
import org.gradle.api.tasks.TaskProvider;

/**
 * The {@code dev.goforge.lawspec} plugin: a {@code lawspec<Command>} task for every lawspec
 * command, and the {@link LawSpecExtension lawspec} extension. {@code lawspecGenerate} runs before
 * main compilation, the directories it generates into join the source sets, and {@code check} runs
 * {@code lawspecCheck} and {@code lawspecTest}; the extension switches each off. The tasks run this
 * platform's {@code dev.goforge:lawspec-<platform>} jar, which the plugin resolves from the
 * project's repositories.
 */
public abstract class LawSpecPlugin implements Plugin<Project>
{
  /** The task group. */
  public static final String GROUP = "lawspec";

  // Each task and the command it runs; a goal of the Maven plugin each.
  private static final Map<String, List<String>> COMMANDS = Map.ofEntries(
      Map.entry("Check", List.of("check")), Map.entry("Generate", List.of("generate")),
      Map.entry("Test", List.of("test")), Map.entry("Prove", List.of("prove")),
      Map.entry("Explain", List.of("explain")), Map.entry("Doctor", List.of("doctor")),
      Map.entry("Fmt", List.of("fmt")), Map.entry("Mutate", List.of("mutate")),
      Map.entry("Package", List.of("package")), Map.entry("Evidence", List.of("evidence")),
      Map.entry("Advise", List.of("advise")), Map.entry("Inspect", List.of("inspect")),
      Map.entry("Prelude", List.of("prelude")),
      Map.entry("Describe", List.of("describe", "--json")), Map.entry("Fetch", List.of("fetch")),
      Map.entry("Update", List.of("update")), Map.entry("Examples", List.of("examples")),
      Map.entry("Init", List.of("init")), Map.entry("ProjectStatus", List.of("project", "status")),
      Map.entry("ProjectValidate", List.of("project", "validate")),
      Map.entry("Learn", List.of("learn")));

  /** Creates the plugin. */
  public LawSpecPlugin()
  {
  }

  /**
   * Registers the lawspec extension, the task for each command and the wiring into the build's
   * generation, compilation and check tasks.
   *
   * @param project the project to apply the plugin to
   */
  @Override
  public void apply(Project project)
  {
    LawSpecExtension extension = project.getExtensions().create("lawspec", LawSpecExtension.class);
    extension.getWorkingDirectory().convention(project.getLayout().getProjectDirectory());
    extension.getGenerateBeforeMainCompile().convention(true);
    extension.getAddSourceRoots().convention(true);
    extension.getCheckOnCheck().convention(true);
    extension.getTestOnCheck().convention(true);

    // The jars of the plugin's own version: the launcher it runs them with
    // is that version, and its manifest verifies only that version's binary.
    String platform = Platform.current();
    String version = pluginVersion();
    Configuration nativeJar = jarConfiguration(project, version, "lawspecNative",
        "lawspec-" + platform, "This platform's natively compiled lawspec.");
    Configuration resourcesJar = jarConfiguration(project, version, "lawspecResources",
        "lawspec-resources", "The Learn LawSpec site lawspec learn serves.");

    COMMANDS.forEach((name, command) -> project.getTasks().register("lawspec" + name,
        LawSpecTask.class, task -> {
          task.setGroup(GROUP);
          task.setDescription("Runs lawspec " + String.join(" ", command) + ".");
          task.getCommand().set(command);
          task.getConfig().set(extension.getConfig());
          task.getTarget().set(extension.getTarget());
          task.getWorkingDirectory().set(extension.getWorkingDirectory());
          task.getArguments().set(extension.getArguments());
          task.getEnvironment().set(extension.getEnvironment());
          task.getNativeJar().from(nativeJar);
          if (name.equals("Learn"))
          {
            task.getResourcesJar().from(resourcesJar);
          }
        }));

    TaskProvider<LawSpecTask> generate =
        project.getTasks().named("lawspecGenerate", LawSpecTask.class);
    TaskProvider<LawSpecTask> check = project.getTasks().named("lawspecCheck", LawSpecTask.class);
    TaskProvider<LawSpecTask> test = project.getTasks().named("lawspecTest", LawSpecTask.class);
    // When they run together, lawspec test runs last, as in Maven's verify:
    // after generation, lawspec check and the build's own tests.
    test.configure(task -> task.mustRunAfter(generate, check));

    Provider<List<Object>> generation =
        extension.getGenerateBeforeMainCompile().map(on -> on ? List.of(generate) : List.of());
    for (String[] wiring : new String[][] {{"java", "compileJava"},
        {"org.jetbrains.kotlin.jvm", "compileKotlin"}, {"groovy", "compileGroovy"},
        {"scala", "compileScala"}})
    {
      project.getPluginManager().withPlugin(wiring[0], applied -> project.getTasks()
          .named(wiring[1]).configure(task -> task.dependsOn(generation)));
    }
    project.getPluginManager().withPlugin("java",
        applied -> addSourceRoots(project, extension, nativeJar, generation));
    project.getPluginManager().withPlugin("java",
        applied -> test.configure(task -> task.mustRunAfter(project.getTasks().named("test"))));
    project.getPluginManager().withPlugin("lifecycle-base",
        applied -> project.getTasks().named("check").configure((Task task) -> {
          task.dependsOn(extension.getCheckOnCheck().map(on -> on ? List.of(check) : List.of()));
          task.dependsOn(extension.getTestOnCheck().map(on -> on ? List.of(test) : List.of()));
        }));
  }

  // The generated directories, which lawspec describe reports, join the
  // source sets lazily: a build that compiles nothing never runs it. They are
  // built by lawspecGenerate while it runs before main compilation.
  private static void addSourceRoots(Project project, LawSpecExtension extension,
      Configuration nativeJar, Provider<List<Object>> generation)
  {
    ProviderFactory providers = project.getProviders();
    Provider<Map<String, List<String>>> described =
        providers.of(GeneratedDirectories.class, spec -> {
          GeneratedDirectories.Parameters parameters = spec.getParameters();
          parameters.getNativeJar().from(nativeJar);
          parameters.getConfig().set(extension.getConfig());
          parameters.getWorkingDirectory().set(extension.getWorkingDirectory());
          parameters.getProjectDirectory().set(project.getLayout().getProjectDirectory());
          parameters.getTarget().set(extension.getTarget());
          parameters.getEnvironment().set(extension.getEnvironment());
          parameters.getOffline().set(project.getGradle().getStartParameter().isOffline());
        });
    Provider<Map<String, List<String>>> none = providers.provider(Map::of);
    Provider<Map<String, List<String>>> directories =
        extension.getAddSourceRoots().flatMap(on -> on ? described : none);
    ConfigurableFileCollection sources = project
        .files(
            directories.map(found -> found.getOrDefault(GeneratedDirectories.SOURCES, List.of())))
        .builtBy(generation);
    ConfigurableFileCollection tests = project
        .files(directories.map(found -> found.getOrDefault(GeneratedDirectories.TESTS, List.of())))
        .builtBy(generation);
    SourceSetContainer sourceSets = project.getExtensions().getByType(SourceSetContainer.class);
    sourceSets.named(SourceSet.MAIN_SOURCE_SET_NAME)
        .configure(sourceSet -> sourceSet.getJava().srcDir(sources));
    sourceSets.named(SourceSet.TEST_SOURCE_SET_NAME)
        .configure(sourceSet -> sourceSet.getJava().srcDir(tests));
    project.getTasks().named(JavaPlugin.PROCESS_TEST_RESOURCES_TASK_NAME, Copy.class)
        .configure(task -> task.from(tests, copy -> copy.exclude("**/*.java")));
  }

  private static Configuration jarConfiguration(Project project, String version, String name,
      String artifact, String description)
  {
    DependencyFactory dependencies = project.getDependencyFactory();
    return project.getConfigurations().create(name, configuration -> {
      configuration.setDescription(description);
      configuration.setCanBeConsumed(false);
      configuration.setCanBeResolved(true);
      configuration.setVisible(false);
      configuration.setTransitive(false);
      configuration.getDependencies().add(dependencies.create("dev.goforge", artifact, version));
    });
  }

  private static String pluginVersion()
  {
    Properties properties = new Properties();
    try (InputStream in = LawSpecPlugin.class.getResourceAsStream("plugin.properties"))
    {
      properties.load(in);
    }
    catch (IOException e)
    {
      throw new UncheckedIOException(e);
    }
    return properties.getProperty("version");
  }
}
