package dev.goforge.lawspec;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.FileTime;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class InstallationTest
{
  private static final String NATIVE = "dev/goforge/lawspec/native/";
  private static final String RESOURCES = "dev/goforge/lawspec/resources/";

  @TempDir
  static Path shared;

  private static Path platformJar;

  @TempDir
  Path scratch;

  private static Path staged()
  {
    return Path.of(System.getProperty("lawspec.test.natives"), Platform.current(), "lawspec");
  }

  // The staged Canon bundle: the canon executable, canon.json and presets/.
  private static Path stagedCanon()
  {
    return Path.of(System.getProperty("lawspec.test.natives"), Platform.current(), "canon");
  }

  private Path jar(String name, Map<String, byte[]> entries) throws IOException
  {
    Path jar = scratch.resolve(name);
    try (ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(jar)))
    {
      for (Map.Entry<String, byte[]> entry : entries.entrySet())
      {
        ZipEntry zipEntry = new ZipEntry(entry.getKey());
        zipEntry.setLastModifiedTime(FileTime.fromMillis(1_700_000_000_000L));
        out.putNextEntry(zipEntry);
        out.write(entry.getValue());
        out.closeEntry();
      }
    }
    return jar;
  }

  // One platform jar of the staged binary and Canon bundle serves every test.
  @BeforeAll
  static void packPlatformJar() throws IOException
  {
    platformJar = shared.resolve("platform.jar");
    try (ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(platformJar));
        Stream<Path> bundle = Files.walk(stagedCanon()))
    {
      out.putNextEntry(new ZipEntry(NATIVE + Platform.current() + "/lawspec"));
      Files.copy(staged(), out);
      out.closeEntry();
      for (Path file : (Iterable<Path>) bundle.filter(Files::isRegularFile).sorted()::iterator)
      {
        String name = stagedCanon().relativize(file).toString().replace('\\', '/');
        if (name.equals("canon.sha256"))
        {
          continue;
        }
        out.putNextEntry(new ZipEntry(NATIVE + Platform.current() + "/canon/" + name));
        Files.copy(file, out);
        out.closeEntry();
      }
    }
  }

  private static Path platformJar()
  {
    return platformJar;
  }

  private static String output(List<String> command, Path directory)
      throws IOException, InterruptedException
  {
    Process process =
        new ProcessBuilder(command).directory(directory.toFile()).redirectErrorStream(true).start();
    String text = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
    assertEquals(0, process.waitFor(), text);
    return text;
  }

  @Test
  void unpacksAndVerifiesTheBinary() throws Exception
  {
    Installation installation = Installation.of(platformJar(), null);
    assertTrue(Files.isExecutable(installation.binary()));
    assertEquals(Files.size(staged()), Files.size(installation.binary()));
    String version = Installation.launcherVersion().replace("-SNAPSHOT", "");
    assertEquals(version + "\n", output(installation.command(List.of("--version")), scratch));
    assertTrue(installation.resources().isEmpty());
    assertTrue(installation.environment().keySet().stream()
        .allMatch(name -> name.equals("LAWSPEC_CANON")));
    // A second run reuses the unpacked binary.
    assertEquals(installation.binary(), Installation.of(platformJar(), null).binary());
  }

  @Test
  void refusesABinaryTheManifestDoesNotRecord() throws Exception
  {
    Path tampered = jar("tampered.jar",
        Map.of(NATIVE + Platform.current() + "/lawspec", new byte[(int) Files.size(staged())]));
    // Only a binary that is not cached yet is read from the jar.
    String previous = System.getProperty(Installation.CACHE_PROPERTY);
    System.setProperty(Installation.CACHE_PROPERTY, scratch.resolve("cache").toString());
    try
    {
      LawSpecException failure =
          assertThrows(LawSpecException.class, () -> Installation.of(tampered, null));
      assertTrue(failure.getMessage().contains("does not match this launcher's manifest"),
          failure.getMessage());
      LawSpecException missing = assertThrows(LawSpecException.class,
          () -> Installation.of(jar("empty.jar", Map.of("x", new byte[0])), null));
      assertTrue(missing.getMessage().contains("has no " + NATIVE), missing.getMessage());
    }
    finally
    {
      System.setProperty(Installation.CACHE_PROPERTY, previous);
    }
  }

  @Test
  void unpacksTheResourcesWithTheirTimes() throws Exception
  {
    Path resources = jar("resources.jar",
        Map.of(RESOURCES + "core_jsffi.js", "glue".getBytes(StandardCharsets.UTF_8),
            RESOURCES + "learn/index.html", "<p>".getBytes(StandardCharsets.UTF_8),
            "META-INF/MANIFEST.MF", new byte[0]));
    Installation installation = Installation.of(platformJar(), resources);
    Path directory = installation.resources().orElseThrow();
    assertEquals("glue", Files.readString(directory.resolve("core_jsffi.js")));
    assertEquals("<p>", Files.readString(directory.resolve("learn/index.html")));
    assertTrue(Files.notExists(directory.resolve("META-INF")));
    assertEquals(1_700_000_000_000L,
        Files.getLastModifiedTime(directory.resolve("core_jsffi.js")).toMillis());
    if (System.getenv("LAWSPEC_RESOURCES") == null)
    {
      assertEquals(directory.toString(), installation.environment().get("LAWSPEC_RESOURCES"));
    }
  }

  @Test
  void unpacksAndVerifiesTheCanonBundle() throws Exception
  {
    Installation installation = Installation.of(platformJar(), null);
    Path canon = installation.canon().orElseThrow();
    assertTrue(Files.isExecutable(canon.resolve("canon")));
    assertEquals(Files.size(stagedCanon().resolve("canon")), Files.size(canon.resolve("canon")));
    assertTrue(output(List.of(canon.resolve("canon").toString(), "version"), scratch)
        .startsWith("canon "));
    assertEquals(Files.readString(stagedCanon().resolve("presets/languages.json")),
        Files.readString(canon.resolve("presets/languages.json")));
    if (System.getenv("LAWSPEC_CANON") == null)
    {
      assertEquals(canon.toString(), installation.environment().get("LAWSPEC_CANON"));
    }
    // A second run reuses the unpacked bundle.
    assertEquals(canon, Installation.of(platformJar(), null).canon().orElseThrow());
  }

  @Test
  void refusesACanonTheManifestDoesNotRecord() throws Exception
  {
    String platform = Platform.current();
    Path tampered = jar("tampered-canon.jar",
        Map.of(NATIVE + platform + "/lawspec", Files.readAllBytes(staged()),
            NATIVE + platform + "/canon/canon",
            new byte[(int) Files.size(stagedCanon().resolve("canon"))]));
    LawSpecException failure =
        assertThrows(LawSpecException.class, () -> Installation.of(tampered, null));
    assertTrue(failure.getMessage().contains("Canon in " + tampered), failure.getMessage());
    Path missing =
        jar("no-canon.jar", Map.of(NATIVE + platform + "/lawspec", Files.readAllBytes(staged())));
    LawSpecException absent =
        assertThrows(LawSpecException.class, () -> Installation.of(missing, null));
    assertTrue(absent.getMessage().contains("has no " + NATIVE + platform + "/canon/canon"),
        absent.getMessage());
  }

  @Test
  void runsWithTheArgumentsAndExitCodePassedThrough() throws Exception
  {
    Installation installation = Installation.of(platformJar(), null);
    assertEquals(0, LawSpec.run(installation, List.of("--version"), scratch));
    // A usage error is the binary's own exit code.
    assertEquals(1, LawSpec.run(installation, List.of("no-such-command"), scratch));
  }

  @Test
  void answersCompilerApiRequests() throws Exception
  {
    Compiler compiler = LawSpec.createCompiler(Installation.of(platformJar(), null));
    String prelude = compiler.prelude("{\"query\":\"length\"}");
    assertTrue(prelude.startsWith("{") && prelude.contains("\"schemaVersion\":5"), prelude);
    String check =
        compiler.check("{\"sources\":[{\"path\":\"a.lawspec\",\"text\":\"unit a\\n\"}]}");
    assertTrue(check.contains("\"schemaVersion\":5"), check);
  }

  @Test
  void writesNothingOutsideTheCache() throws Exception
  {
    Path before = scratch.resolve("marker");
    try (OutputStream out = Files.newOutputStream(before))
    {
      out.write(1);
    }
    Installation.of(platformJar(), null);
    assertEquals(List.of("marker"),
        Files.list(scratch).map(path -> path.getFileName().toString()).sorted().toList());
  }
}
