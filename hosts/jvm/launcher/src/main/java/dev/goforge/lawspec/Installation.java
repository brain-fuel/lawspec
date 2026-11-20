package dev.goforge.lawspec;

import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.UncheckedIOException;
import java.net.JarURLConnection;
import java.net.URISyntaxException;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.DirectoryNotEmptyException;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.DigestOutputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.Enumeration;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.Properties;
import java.util.stream.Stream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * An unpacked, verified native {@code lawspec}: this platform's binary from its platform jar, the
 * Canon bundle {@code lawspec project} runs from the same jar and, when the resources jar is there,
 * the package resources {@code lawspec learn} serves.
 *
 * <p>
 * The binary is unpacked once into the cache, as {@code native/<sha256>/lawspec}, and only after
 * its SHA-256 matches the one this launcher's manifest records for the platform; a later run reuses
 * it when its size still matches. The Canon bundle (the {@code canon} executable, verified the same
 * way, and Rice's Tax's presets) is unpacked once per platform jar into {@code canon/<key>}. The
 * resources are unpacked once per resources jar. The cache is
 * {@code lawspec/jvm} in the user cache directory ({@code ~/Library/Caches} on macOS,
 * {@code $XDG_CACHE_HOME} or {@code ~/.cache} on Linux), or the directory the
 * {@value #CACHE_PROPERTY} system property or {@code LAWSPEC_JVM_CACHE} names.
 *
 * <p>
 * Nothing here interprets a LawSpec command: the binary does all of that.
 */
public final class Installation
{
  /** The system property naming the platform jar to use; {@code LAWSPEC_NATIVE_JAR} also does. */
  public static final String NATIVE_JAR_PROPERTY = "lawspec.native.jar";

  /** The system property naming the resources jar; {@code LAWSPEC_RESOURCES_JAR} also does. */
  public static final String RESOURCES_JAR_PROPERTY = "lawspec.resources.jar";

  /** The system property naming the cache directory; {@code LAWSPEC_JVM_CACHE} also does. */
  public static final String CACHE_PROPERTY = "lawspec.jvm.cache";

  private static final String PACKAGE = "dev/goforge/lawspec/";
  private static final String RESOURCES = PACKAGE + "resources/";
  private static final String RESOURCES_MARKER = RESOURCES + "core_jsffi.js";

  private final String platform;
  private final String version;
  private final Path binary;
  private final Path resources;
  private final Path canon;

  private Installation(String platform, String version, Path binary, Path resources, Path canon)
  {
    this.platform = platform;
    this.version = version;
    this.binary = binary;
    this.resources = resources;
    this.canon = canon;
  }

  /**
   * Finds this platform's jar and the resources jar, then unpacks and verifies them. Each is looked
   * for, in order, where its system property or environment variable names it, on the class path
   * (which {@code java -jar} extends with the jars beside the launcher) and in the local Maven
   * repository. The resources jar is optional.
   *
   * @return the installation
   * @throws LawSpecException if the platform jar is missing or its binary does not verify
   */
  public static Installation locate()
  {
    String platform = Platform.current();
    String version = launcherVersion();
    String artifact = "lawspec-" + platform;
    Source binary = configured(NATIVE_JAR_PROPERTY, "LAWSPEC_NATIVE_JAR")
        .or(() -> onClassPath(nativeEntry(platform))).or(() -> inLocalRepository(artifact, version))
        .map(jar -> Source.inJar(jar, nativeEntry(platform)))
        .or(() -> Source.onClassPath(nativeEntry(platform)))
        .orElseThrow(() -> new LawSpecException("No " + artifact + " jar was found. Put " + artifact
            + "-" + version + ".jar beside lawspec-" + version + ".jar, install dev.goforge:"
            + artifact + ":" + version + " in the local Maven repository, or name the jar with -D"
            + NATIVE_JAR_PROPERTY + "=<path>."));
    Optional<Path> resources = configured(RESOURCES_JAR_PROPERTY, "LAWSPEC_RESOURCES_JAR")
        .or(() -> onClassPath(RESOURCES_MARKER))
        .or(() -> inLocalRepository("lawspec-resources", version));
    return unpack(platform, version, binary, resources.orElse(null));
  }

  /**
   * Unpacks and verifies this platform's binary from a platform jar, with the package resources
   * from a resources jar when one is given. Build plugins call this with the jars they resolved.
   *
   * @param platformJar the {@code dev.goforge:lawspec-<platform>} jar of this launcher's version
   * @param resourcesJar the {@code dev.goforge:lawspec-resources} jar, or {@code null}
   * @return the installation
   * @throws LawSpecException if the binary is missing from the jar or does not verify
   */
  public static Installation of(Path platformJar, Path resourcesJar)
  {
    String platform = Platform.current();
    return unpack(platform, launcherVersion(), Source.inJar(platformJar, nativeEntry(platform)),
        resourcesJar);
  }

  /**
   * Returns the coordinates of this platform's jar, for build plugins to resolve.
   *
   * @return {@code dev.goforge:lawspec-<platform>:<version>}
   */
  public static String platformCoordinates()
  {
    return "dev.goforge:lawspec-" + Platform.current() + ":" + launcherVersion();
  }

  /**
   * Returns the coordinates of the resources jar, for build plugins to resolve.
   *
   * @return {@code dev.goforge:lawspec-resources:<version>}
   */
  public static String resourcesCoordinates()
  {
    return "dev.goforge:lawspec-resources:" + launcherVersion();
  }

  /**
   * Returns this launcher's version, which its platform and resources jars share.
   *
   * @return the version
   */
  public static String launcherVersion()
  {
    return properties("launcher.properties").getProperty("version");
  }

  /**
   * Returns the platform this installation runs on.
   *
   * @return the platform name
   */
  public String platform()
  {
    return platform;
  }

  /**
   * Returns the launcher version.
   *
   * @return the version
   */
  public String version()
  {
    return version;
  }

  /**
   * Returns the verified, unpacked native {@code lawspec}.
   *
   * @return its path
   */
  public Path binary()
  {
    return binary;
  }

  /**
   * Returns the unpacked package resources, when the resources jar was found.
   *
   * @return their directory
   */
  public Optional<Path> resources()
  {
    return Optional.ofNullable(resources);
  }

  /**
   * Returns the unpacked Canon bundle: the verified {@code canon} executable and the
   * {@code presets} directory beside it. It is absent only when the platform jar is not a file on
   * disk (the binary came from a class path directory) or the manifest records no Canon.
   *
   * @return its directory
   */
  public Optional<Path> canon()
  {
    return Optional.ofNullable(canon);
  }

  /**
   * Returns the command line that runs {@code lawspec} with these arguments.
   *
   * @param arguments the arguments, passed through unchanged
   * @return the binary followed by the arguments
   */
  public List<String> command(List<String> arguments)
  {
    List<String> command = new ArrayList<>(arguments.size() + 1);
    command.add(binary.toString());
    command.addAll(arguments);
    return command;
  }

  /**
   * Returns the environment variables to add to the inherited environment: {@code
   * LAWSPEC_RESOURCES}, naming the unpacked resources, and {@code LAWSPEC_CANON}, naming the
   * unpacked Canon bundle, each unless it is already set. ({@code CANON}, a canon executable a
   * user names, still takes precedence over the bundle in {@code lawspec project}.)
   *
   * @return the variables to add
   */
  public Map<String, String> environment()
  {
    Map<String, String> variables = new HashMap<>();
    if (resources != null && System.getenv("LAWSPEC_RESOURCES") == null)
    {
      variables.put("LAWSPEC_RESOURCES", resources.toString());
    }
    if (canon != null && System.getenv("LAWSPEC_CANON") == null)
    {
      variables.put("LAWSPEC_CANON", canon.toString());
    }
    return Map.copyOf(variables);
  }

  private static String nativeEntry(String platform)
  {
    return PACKAGE + "native/" + platform + "/lawspec";
  }

  private static String canonPrefix(String platform)
  {
    return PACKAGE + "native/" + platform + "/canon/";
  }

  private static Installation unpack(String platform, String version, Source source,
      Path resourcesJar)
  {
    Properties manifest = properties("natives.properties");
    String sha256 = manifest.getProperty(platform + ".sha256");
    String size = manifest.getProperty(platform + ".size");
    if (sha256 == null || size == null)
    {
      throw new LawSpecException(
          "This LawSpec launcher (" + version + ") records no native binary for " + platform + ".");
    }
    Path cache = cacheDirectory();
    Path binary = unpackBinary(cache, platform, sha256, Long.parseLong(size), source);
    Path resources = resourcesJar == null ? null : unpackResources(cache, version, resourcesJar);
    String canonSha256 = manifest.getProperty(platform + ".canon.sha256");
    String canonSize = manifest.getProperty(platform + ".canon.size");
    Path canon = canonSha256 == null || canonSize == null || source.jar().isEmpty() ? null
        : unpackCanon(cache, platform, canonSha256, Long.parseLong(canonSize), source.jar().get());
    return new Installation(platform, version, binary, resources, canon);
  }

  // The Canon bundle is unpacked whole into a temporary sibling, the executable checked against
  // the manifest's SHA-256, then renamed into place, so a directory that exists is complete. It is
  // keyed by the executable's digest and the platform jar, whose presets it holds.
  private static Path unpackCanon(Path cache, String platform, String sha256, long size, Path jar)
  {
    Path parent = cache.resolve("canon");
    String prefix = canonPrefix(platform);
    try
    {
      String identity = sha256 + "\n" + jar.toRealPath() + "\n" + Files.size(jar) + "\n"
          + Files.getLastModifiedTime(jar).toMillis();
      String key = HexFormat.of()
          .formatHex(sha256().digest(identity.getBytes(StandardCharsets.UTF_8))).substring(0, 32);
      Path directory = parent.resolve(key);
      Path executable = directory.resolve("canon");
      if (Files.isRegularFile(executable) && Files.size(executable) == size
          && Files.isExecutable(executable))
      {
        return directory;
      }
      Files.createDirectories(parent);
      Path partial = Files.createTempDirectory(parent, "partial").toAbsolutePath().normalize();
      try
      {
        String actual = null;
        try (ZipFile zip = new ZipFile(jar.toFile()))
        {
          for (Enumeration<? extends ZipEntry> entries = zip.entries(); entries.hasMoreElements();)
          {
            ZipEntry entry = entries.nextElement();
            if (!entry.getName().startsWith(prefix) || entry.isDirectory())
            {
              continue;
            }
            Path target = partial.resolve(entry.getName().substring(prefix.length())).normalize();
            if (!target.startsWith(partial))
            {
              throw new LawSpecException("Unsafe entry in " + jar + ": " + entry.getName());
            }
            Files.createDirectories(target.getParent());
            MessageDigest digest = sha256();
            try (InputStream in = zip.getInputStream(entry);
                OutputStream out = new DigestOutputStream(Files.newOutputStream(target), digest))
            {
              in.transferTo(out);
            }
            if (target.equals(partial.resolve("canon")))
            {
              actual = HexFormat.of().formatHex(digest.digest());
            }
          }
        }
        if (actual == null)
        {
          throw new LawSpecException(jar + " has no " + prefix + "canon.");
        }
        if (!actual.equals(sha256))
        {
          throw new LawSpecException("The " + platform + " Canon in " + jar
              + " does not match this launcher's manifest: SHA-256 " + actual + ", expected "
              + sha256 + ".");
        }
        Files.setPosixFilePermissions(partial.resolve("canon"),
            PosixFilePermissions.fromString("rwxr-xr-x"));
        try
        {
          move(partial, directory);
        }
        catch (FileAlreadyExistsException | DirectoryNotEmptyException e)
        {
          // Another run unpacked the same jar first.
        }
      }
      finally
      {
        deleteTree(partial);
      }
      return directory;
    }
    catch (IOException e)
    {
      throw new LawSpecException(
          "Cannot unpack the " + platform + " Canon from " + jar + ": " + e.getMessage(), e);
    }
  }

  private static Path unpackBinary(Path cache, String platform, String sha256, long size,
      Source source)
  {
    Path directory = cache.resolve("native").resolve(sha256);
    Path binary = directory.resolve("lawspec");
    try
    {
      if (Files.isRegularFile(binary) && Files.size(binary) == size && Files.isExecutable(binary))
      {
        return binary;
      }
      Files.createDirectories(directory);
      Path partial = Files.createTempFile(directory, "lawspec", ".partial");
      try
      {
        MessageDigest digest = sha256();
        try (InputStream in = source.open();
            OutputStream out = new DigestOutputStream(Files.newOutputStream(partial), digest))
        {
          in.transferTo(out);
        }
        String actual = HexFormat.of().formatHex(digest.digest());
        if (!actual.equals(sha256))
        {
          throw new LawSpecException("The " + platform + " binary in " + source
              + " does not match this launcher's manifest: SHA-256 " + actual + ", expected "
              + sha256 + ".");
        }
        Files.setPosixFilePermissions(partial, PosixFilePermissions.fromString("rwxr-xr-x"));
        move(partial, binary);
      }
      finally
      {
        Files.deleteIfExists(partial);
      }
      return binary;
    }
    catch (IOException e)
    {
      throw new LawSpecException(
          "Cannot unpack the " + platform + " binary into " + directory + ": " + e.getMessage(), e);
    }
  }

  // The resources are unpacked whole into a temporary sibling, then renamed into place, so a
  // directory that exists is complete. Each entry keeps its archive time: lawspec learn serves
  // core.wasm.gz only when it is no older than core.wasm.
  private static Path unpackResources(Path cache, String version, Path jar)
  {
    Path parent = cache.resolve("resources");
    try
    {
      String identity = version + "\n" + jar.toRealPath() + "\n" + Files.size(jar) + "\n"
          + Files.getLastModifiedTime(jar).toMillis();
      String key = HexFormat.of()
          .formatHex(sha256().digest(identity.getBytes(StandardCharsets.UTF_8))).substring(0, 32);
      Path directory = parent.resolve(key);
      if (Files.isDirectory(directory))
      {
        return directory;
      }
      Files.createDirectories(parent);
      Path partial = Files.createTempDirectory(parent, "partial").toAbsolutePath().normalize();
      try
      {
        try (ZipFile zip = new ZipFile(jar.toFile()))
        {
          for (Enumeration<? extends ZipEntry> entries = zip.entries(); entries.hasMoreElements();)
          {
            ZipEntry entry = entries.nextElement();
            if (!entry.getName().startsWith(RESOURCES) || entry.getName().equals(RESOURCES))
            {
              continue;
            }
            Path target =
                partial.resolve(entry.getName().substring(RESOURCES.length())).normalize();
            if (!target.startsWith(partial))
            {
              throw new LawSpecException("Unsafe entry in " + jar + ": " + entry.getName());
            }
            if (entry.isDirectory())
            {
              Files.createDirectories(target);
              continue;
            }
            Files.createDirectories(target.getParent());
            try (InputStream in = zip.getInputStream(entry))
            {
              Files.copy(in, target);
            }
            Files.setLastModifiedTime(target, entry.getLastModifiedTime());
          }
        }
        try
        {
          move(partial, directory);
        }
        catch (FileAlreadyExistsException | DirectoryNotEmptyException e)
        {
          // Another run unpacked the same jar first.
        }
      }
      finally
      {
        deleteTree(partial);
      }
      return directory;
    }
    catch (IOException e)
    {
      throw new LawSpecException(
          "Cannot unpack the LawSpec resources from " + jar + ": " + e.getMessage(), e);
    }
  }

  private static void move(Path from, Path to) throws IOException
  {
    try
    {
      Files.move(from, to, StandardCopyOption.ATOMIC_MOVE);
    }
    catch (AtomicMoveNotSupportedException e)
    {
      Files.move(from, to);
    }
  }

  private static void deleteTree(Path root) throws IOException
  {
    if (!Files.exists(root))
    {
      return;
    }
    try (Stream<Path> paths = Files.walk(root))
    {
      for (Path path : (Iterable<Path>) paths.sorted(Comparator.reverseOrder())::iterator)
      {
        Files.deleteIfExists(path);
      }
    }
  }

  private static Path cacheDirectory()
  {
    Optional<String> configured = setting(CACHE_PROPERTY, "LAWSPEC_JVM_CACHE");
    if (configured.isPresent())
    {
      return Path.of(configured.get()).toAbsolutePath().normalize();
    }
    Path home = Path.of(System.getProperty("user.home"));
    String os = System.getProperty("os.name", "").toLowerCase(Locale.ROOT);
    Path base;
    if (os.startsWith("mac"))
    {
      base = home.resolve("Library").resolve("Caches");
    }
    else
    {
      String xdg = System.getenv("XDG_CACHE_HOME");
      base = xdg != null && !xdg.isEmpty() ? Path.of(xdg) : home.resolve(".cache");
    }
    return base.resolve("lawspec").resolve("jvm");
  }

  private static Optional<String> setting(String property, String variable)
  {
    String value = System.getProperty(property);
    if (value == null || value.isEmpty())
    {
      value = System.getenv(variable);
    }
    return value == null || value.isEmpty() ? Optional.empty() : Optional.of(value);
  }

  private static Optional<Path> configured(String property, String variable)
  {
    return setting(property, variable).map(Path::of);
  }

  // The jar that holds a resource on the class path, when it is a jar file.
  private static Optional<Path> onClassPath(String entry)
  {
    URL url = Installation.class.getClassLoader().getResource(entry);
    if (url == null || !"jar".equals(url.getProtocol()))
    {
      return Optional.empty();
    }
    try
    {
      JarURLConnection connection = (JarURLConnection) url.openConnection();
      URL jar = connection.getJarFileURL();
      return "file".equals(jar.getProtocol()) ? Optional.of(Path.of(jar.toURI()))
          : Optional.empty();
    }
    catch (IOException | URISyntaxException e)
    {
      return Optional.empty();
    }
  }

  private static Optional<Path> inLocalRepository(String artifact, String version)
  {
    Path repository = setting("maven.repo.local", "LAWSPEC_MAVEN_REPOSITORY").map(Path::of)
        .orElse(Path.of(System.getProperty("user.home"), ".m2", "repository"));
    Path jar = repository.resolve("dev").resolve("goforge").resolve(artifact).resolve(version)
        .resolve(artifact + "-" + version + ".jar");
    return Files.isRegularFile(jar) ? Optional.of(jar) : Optional.empty();
  }

  private static Properties properties(String name)
  {
    Properties properties = new Properties();
    try (InputStream in = Installation.class.getResourceAsStream(name))
    {
      if (in == null)
      {
        throw new LawSpecException("The LawSpec launcher jar has no " + name + ".");
      }
      properties.load(in);
    }
    catch (IOException e)
    {
      throw new UncheckedIOException(e);
    }
    return properties;
  }

  private static MessageDigest sha256()
  {
    try
    {
      return MessageDigest.getInstance("SHA-256");
    }
    catch (NoSuchAlgorithmException e)
    {
      throw new IllegalStateException(e);
    }
  }

  // Where the binary's bytes come from: an entry of a jar file, or a class path resource.
  private interface Source
  {
    /**
     * Opens the binary's bytes for reading; the caller closes the stream.
     *
     * @return a stream of the bytes
     * @throws IOException if the bytes cannot be read
     */
    InputStream open() throws IOException;

    /**
     * The jar file the bytes come from, when they come from one.
     *
     * @return the jar, or empty for a class path resource
     */
    default Optional<Path> jar()
    {
      return Optional.empty();
    }

    /**
     * A source that reads an entry of a jar file.
     *
     * @param jar the jar file
     * @param entry the name of the entry in it
     * @return the source
     */
    static Source inJar(Path jar, String entry)
    {
      return new Source()
      {
        /**
         * Opens the entry, closing the jar when the stream is closed.
         */
        @Override
        public InputStream open() throws IOException
        {
          ZipFile zip = new ZipFile(jar.toFile());
          ZipEntry found = zip.getEntry(entry);
          if (found == null)
          {
            zip.close();
            throw new LawSpecException(jar + " has no " + entry + ".");
          }
          InputStream in = zip.getInputStream(found);
          return new FilterInputStream(in)
          {
            /**
             * Closes the entry's stream and then the jar it was opened from.
             */
            @Override
            public void close() throws IOException
            {
              try
              {
                super.close();
              }
              finally
              {
                zip.close();
              }
            }
          };
        }

        /**
         * Names the jar this source reads.
         */
        @Override
        public Optional<Path> jar()
        {
          return Optional.of(jar);
        }

        /**
         * Describes the source as the jar's path, for messages.
         */
        @Override
        public String toString()
        {
          return jar.toString();
        }
      };
    }

    /**
     * A source that reads a class path resource, when the class path has it.
     *
     * @param entry the name of the resource
     * @return the source, or empty if the class path has no such resource
     */
    static Optional<Source> onClassPath(String entry)
    {
      if (Installation.class.getClassLoader().getResource(entry) == null)
      {
        return Optional.empty();
      }
      return Optional.of(new Source()
      {
        /**
         * Opens the resource from the launcher's class loader.
         */
        @Override
        public InputStream open() throws IOException
        {
          InputStream in = Installation.class.getClassLoader().getResourceAsStream(entry);
          if (in == null)
          {
            throw new LawSpecException("The class path has no " + entry + ".");
          }
          return in;
        }

        /**
         * Describes the source as the class path, for messages.
         */
        @Override
        public String toString()
        {
          return "the class path";
        }
      });
    }
  }
}
