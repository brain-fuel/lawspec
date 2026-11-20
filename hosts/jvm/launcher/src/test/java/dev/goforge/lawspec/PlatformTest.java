package dev.goforge.lawspec;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import org.junit.jupiter.api.Test;

class PlatformTest
{
  /**
   * The operating system and architecture names map to the platform names of the
   * {@code lawspec-<platform>} artifacts, so the launcher picks the right jar.
   * ref:REQ-jvm-host ref:DEC-maven-central-coordinates
   */
  @Test
  void namesThePlatformsAsTheArtifactsDo()
  {
    assertEquals("darwin-arm64", Platform.of("Mac OS X", "aarch64"));
    assertEquals("darwin-x64", Platform.of("Mac OS X", "x86_64"));
    assertEquals("linux-arm64", Platform.of("Linux", "aarch64"));
    assertEquals("linux-x64", Platform.of("Linux", "amd64"));
  }

  /**
   * A platform without an artifact is refused with an error rather than guessed,
   * so the launcher never runs a binary built for another system.
   * ref:REQ-jvm-host ref:DEC-maven-central-coordinates
   */
  @Test
  void refusesOtherPlatforms()
  {
    assertThrows(LawSpecException.class, () -> Platform.of("Windows 11", "amd64"));
    assertThrows(LawSpecException.class, () -> Platform.of("Linux", "riscv64"));
  }
}
