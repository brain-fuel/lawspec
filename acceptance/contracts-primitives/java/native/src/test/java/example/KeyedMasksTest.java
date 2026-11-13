package example;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import lawspec.data.Session;
import lawspec.definitions.example.Keyed;
import lawspec.runtime.LawSpecMasks;
import org.junit.jupiter.api.Test;

/** The masks a specification calls are the runtime's own, under the same key. */
final class KeyedMasksTest
{
  private static final byte[] KEY =
      "whats the Elvish word for friend".getBytes(StandardCharsets.UTF_8);

  private static final List<String> TEXTS =
      List.of("", "abc", "tok-12345678", "a\u00e9\u20ac\uD83D\uDE00".repeat(300), "x".repeat(5121));

  // test/fixtures/blake3-keyed-text.json: the same rows in every runtime.
  private static final String[][] RECORDED =
      {{"abc", "157f8b4b104070014ab0b3b7aff364f794e010e92b1c976318e892f380b53406"},
          {"\ufffd", "b08a37ba71c80d97211ca1ecbc0e82e0254499a3004691544ffdb4425702ec8e"},};

  @Test
  void maskHashInASpecificationIsTheRuntimeMaskHashUnderTheKey()
  {
    LawSpecMasks.setHashKey(KEY);
    for (String text : TEXTS)
    {
      String shown = Keyed.fingerprint(Map.of(), KEY, text);
      assertEquals(LawSpecMasks.maskHash(text), shown);
      assertEquals(LawSpecMasks.maskHashBlake3(text), shown);
      assertEquals(LawSpecMasks.maskHashWith(KEY, text), shown);
      assertEquals(LawSpecMasks.maskHashBlake3With(KEY, text), shown);
    }
    for (String[] row : RECORDED)
    {
      assertEquals("hash:" + row[1], Keyed.fingerprint(Map.of(), KEY, row[0]));
    }
  }

  @Test
  void aRecordRenderedWithTheKeyIsItsNativeRendering()
  {
    LawSpecMasks.setHashKey(KEY);
    var session = new Session("ann", "tok-12345678", "c");
    String shown = Keyed.maskedSessionWith(Map.of(), KEY, session);
    assertEquals(session.toString(), shown);
    assertTrue(
        shown.matches("Session\\{user=ann, token=hash:[0-9a-f]{64}, device=hash:[0-9a-f]{64}}"),
        shown);
    assertEquals("Session{user=ann, token=***, device=***}",
        Keyed.maskedSession(Map.of(), session));
  }

  @Test
  void aHalfOfASurrogatePairIsHashedAsTheReplacementCharacter()
  {
    String[][] pairs = {{"\uD800", "\ufffd"}, {"\uDC00", "\ufffd"}, {"a\uD83D", "a\ufffd"}};
    for (String[] pair : pairs)
    {
      assertEquals(LawSpecMasks.maskHashWith(KEY, pair[1]),
          LawSpecMasks.maskHashWith(KEY, pair[0]));
    }
    assertEquals("hash:" + RECORDED[1][1], LawSpecMasks.maskHashWith(KEY, "\uD800"));
  }

  @Test
  void aKeyThatIsNot32BytesIsRefused()
  {
    assertThrows(IllegalArgumentException.class,
        () -> LawSpecMasks.maskHashWith(new byte[31], "abc"));
    assertThrows(RuntimeException.class, () -> Keyed.fingerprint(Map.of(), new byte[31], "abc"));
  }

  @Test
  void maskStarShowsNothing()
  {
    assertEquals("***", LawSpecMasks.maskStar("tok-12345678"));
    assertEquals("***", LawSpecMasks.maskStar(1234));
  }
}
