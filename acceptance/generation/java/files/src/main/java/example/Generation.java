// User-owned LawSpec adapter: the portable generator under test.
package example;

import java.math.BigInteger;
import java.util.List;
import lawspec.runtime.LawSpecRuntime;

public final class Generation {
  public static List<String> generated(String value0, BigInteger value1, int value2, int value3) {
    return LawSpecRuntime.generated(value0, value1.longValue(), value2, value3);
  }

  public static List<String> shrunk(String value0, BigInteger value1, int value2) {
    return LawSpecRuntime.shrunk(value0, value1.longValue(), value2);
  }
}
