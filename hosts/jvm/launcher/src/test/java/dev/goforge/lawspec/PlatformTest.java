package dev.goforge.lawspec;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import org.junit.jupiter.api.Test;

class PlatformTest
{
  @Test
  void namesThePlatformsAsTheArtifactsDo()
  {
    assertEquals("darwin-arm64", Platform.of("Mac OS X", "aarch64"));
    assertEquals("darwin-x64", Platform.of("Mac OS X", "x86_64"));
    assertEquals("linux-arm64", Platform.of("Linux", "aarch64"));
    assertEquals("linux-x64", Platform.of("Linux", "amd64"));
  }

  @Test
  void refusesOtherPlatforms()
  {
    assertThrows(LawSpecException.class, () -> Platform.of("Windows 11", "amd64"));
    assertThrows(LawSpecException.class, () -> Platform.of("Linux", "riscv64"));
  }
}
