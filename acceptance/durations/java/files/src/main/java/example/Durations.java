// User-owned LawSpec adapter. A Duration is a java.time.Duration.
package example;

import java.time.Duration;

public final class Durations {
  public static Duration remaining(Duration value0, Duration value1) {
    if (value1.compareTo(value0) >= 0) return Duration.ZERO;
    return value0.minus(value1);
  }
}
