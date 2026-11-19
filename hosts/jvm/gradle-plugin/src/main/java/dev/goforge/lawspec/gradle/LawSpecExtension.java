package dev.goforge.lawspec.gradle;

import org.gradle.api.file.DirectoryProperty;
import org.gradle.api.file.RegularFileProperty;
import org.gradle.api.provider.ListProperty;
import org.gradle.api.provider.MapProperty;
import org.gradle.api.provider.Property;

/**
 * The {@code lawspec { }} extension: what every LawSpec task shares, and which tasks the plugin
 * wires into the build.
 *
 * <pre>
 * lawspec {
 *   config = file("lawspec.edn")
 *   generateBeforeMainCompile = true  // lawspecGenerate before compileJava, compileKotlin, ...
 *   addSourceRoots = true             // the generated directories in the source sets
 *   checkOnCheck = true               // lawspecCheck in check
 *   testOnCheck = true                // lawspecTest in check
 * }
 * </pre>
 */
public abstract class LawSpecExtension
{
  /**
   * The project manifest, passed as {@code --config}; lawspec finds {@code lawspec.edn} without it.
   *
   * @return the manifest
   */
  public abstract RegularFileProperty getConfig();

  /**
   * The directory lawspec runs in; the project directory by default.
   *
   * @return the directory
   */
  public abstract DirectoryProperty getWorkingDirectory();

  /**
   * The target language, passed as {@code --target}.
   *
   * @return the target
   */
  public abstract Property<String> getTarget();

  /**
   * Arguments every task appends, after its own.
   *
   * @return the arguments
   */
  public abstract ListProperty<String> getArguments();

  /**
   * Environment variables to set for lawspec, beside the inherited ones.
   *
   * @return the variables
   */
  public abstract MapProperty<String, String> getEnvironment();

  /**
   * Whether {@code lawspecGenerate} runs before main compilation: {@code compileJava}, and {@code
   * compileKotlin}, {@code compileGroovy} or {@code compileScala} when those plugins are applied.
   * Test compilation follows main compilation. On by default.
   *
   * @return the switch
   */
  public abstract Property<Boolean> getGenerateBeforeMainCompile();

  /**
   * Whether the plugin adds the directories {@code lawspec generate} writes into to the source
   * sets, as {@code lawspec describe --json} reports the targets: a target's
   * {@code :generated-source-dir} to the main Java sources, and its {@code :generated-test-dir} to
   * the test Java sources and, without the Java files, to the test resources. While
   * {@link #getGenerateBeforeMainCompile()} is on, {@code lawspecGenerate} builds them. A target
   * without them generates into the source sets' own directories. On by default.
   *
   * @return the switch
   */
  public abstract Property<Boolean> getAddSourceRoots();

  /**
   * Whether {@code check} runs {@code lawspecCheck}. On by default.
   *
   * @return the switch
   */
  public abstract Property<Boolean> getCheckOnCheck();

  /**
   * Whether {@code check} runs {@code lawspecTest}. On by default.
   *
   * @return the switch
   */
  public abstract Property<Boolean> getTestOnCheck();
}
