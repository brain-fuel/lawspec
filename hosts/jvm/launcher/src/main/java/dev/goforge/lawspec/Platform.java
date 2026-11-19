package dev.goforge.lawspec;

import java.util.Locale;

/**
 * The platforms LawSpec ships a native binary for, named as the platform artifacts are:
 * {@code darwin-arm64}, {@code darwin-x64}, {@code linux-arm64} and {@code linux-x64}.
 */
public final class Platform
{
  private Platform()
  {
  }

  /**
   * Returns this JVM's platform.
   *
   * @return the platform name, for example {@code darwin-arm64}
   * @throws LawSpecException if LawSpec ships no binary for this operating system or architecture
   */
  public static String current()
  {
    return of(System.getProperty("os.name", ""), System.getProperty("os.arch", ""));
  }

  /**
   * Returns the platform of an operating system and architecture as the JVM names them.
   *
   * @param osName the {@code os.name} system property
   * @param osArch the {@code os.arch} system property
   * @return the platform name
   * @throws LawSpecException if LawSpec ships no binary for them
   */
  public static String of(String osName, String osArch)
  {
    String name = osName.toLowerCase(Locale.ROOT);
    String os;
    if (name.startsWith("mac") || name.startsWith("darwin"))
    {
      os = "darwin";
    }
    else if (name.startsWith("linux"))
    {
      os = "linux";
    }
    else
    {
      throw new LawSpecException("LawSpec ships no native binary for " + osName
          + "; it runs on macOS and Linux (arm64, x64). On Windows use the npm package.");
    }
    String arch;
    switch (osArch.toLowerCase(Locale.ROOT))
    {
      case "aarch64":
      case "arm64":
        arch = "arm64";
        break;
      case "amd64":
      case "x86_64":
        arch = "x64";
        break;
      default:
        throw new LawSpecException("LawSpec ships no native binary for " + osName + " on " + osArch
            + "; it runs on arm64 and x64.");
    }
    return os + "-" + arch;
  }
}
