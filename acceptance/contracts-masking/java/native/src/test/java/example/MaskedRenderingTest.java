package example;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.LoggerContext;
import ch.qos.logback.classic.PatternLayout;
import ch.qos.logback.classic.encoder.PatternLayoutEncoder;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.OutputStreamAppender;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import lawspec.data.Card;
import lawspec.data.Session;
import lawspec.runtime.LawSpecMasked;
import lawspec.runtime.LawSpecMasks;
import org.junit.jupiter.api.Test;
import org.slf4j.LoggerFactory;

/** A masked record's native rendering and what a logger prints of it. */
final class MaskedRenderingTest
{
  private static final Card CARD =
      new Card("Ann Lee", "4111111111111111", "ann@example.org", 900, 1234);

  private static final String MASKED =
      "Card{holder=***, number=***1111, contact=a***@example.org, limit=900, pin=***}";

  private static void assertNothingRaw(String text)
  {
    for (String raw : List.of("Ann Lee", "4111111111111111", "ann@example.org", "1234"))
    {
      assertFalse(text.contains(raw), () -> "shows " + raw + ": " + text);
    }
  }

  @Test
  void toStringIsTheCheckedMaskedRendering()
  {
    assertEquals(MASKED, CARD.toString());
    assertEquals(lawspec.definitions.example.Masking.maskedCard(Map.of(), CARD), CARD.toString());
    assertNothingRaw("card: " + CARD);
    assertNothingRaw(String.format("%s", CARD));
    assertNothingRaw(List.of(CARD).toString());
  }

  @Test
  void theUnmaskedRenderingIsExplicit()
  {
    assertTrue(CARD.toUnmaskedString().contains("4111111111111111"));
    assertTrue(CARD.toUnmaskedString().contains("ann@example.org"));
  }

  @Test
  void aLoggerPrintsNothingRaw()
  {
    var context = (LoggerContext) LoggerFactory.getILoggerFactory();
    var captured = new ByteArrayOutputStream();
    var encoder = new PatternLayoutEncoder();
    encoder.setContext(context);
    PatternLayout.DEFAULT_CONVERTER_SUPPLIER_MAP.put(
        "maskedMsg", lawspec.logging.LawSpecMaskedConverter::new);
    encoder.setPattern("%level plain: %msg | hook: %maskedMsg%n");
    encoder.start();
    var appender = new OutputStreamAppender<ILoggingEvent>();
    appender.setContext(context);
    appender.setEncoder(encoder);
    appender.setOutputStream(captured);
    appender.start();
    Logger logger = context.getLogger("example.masked");
    logger.setAdditive(false);
    logger.addAppender(appender);

    logger.info("placed {}", CARD);
    logger.info("placed {}", LawSpecMasked.of(CARD));
    logger.info("placed {} and {}", new Object[] {new Card[] {CARD}, LawSpecMasked.of(new Card[] {CARD})});

    appender.stop();
    String output = captured.toString(StandardCharsets.UTF_8);
    assertNothingRaw(output);
    assertTrue(output.contains("INFO plain: placed " + MASKED + " | hook: placed " + MASKED), output);
    assertTrue(output.contains("[" + MASKED + "]"), output);
  }

  // Keyed BLAKE3-256 under the key below, from test/fixtures/blake3-keyed-text.json: the digests
  // LawSpec's Haskell port computes. They tie this runtime to it.
  private static final String[][] LETTERS = {
    {"0", "92b2b75604ed3c761f9d6f62392c8a9227ad0ea3f09573e783f1498a4ed60d26"},
    {"1", "36a6d4db841fe91831fe6d0fe35623a3a47269dd94d84ac68cb8ba7cd26ba3a2"},
    {"64", "81873b794210dfd69cc8d2124ae9606f741743c60ef56d1eacd7a2a98d4d5807"},
    {"65", "a3e4916d04ae832e039226fcae19845b35de0289e59dceb7d51a6994d806d3e2"},
    {"1024", "1e585da86aa6772d1792955fed46e2fe7362f5564b64612c88602b964538986a"},
    {"1025", "09fbf44f6e68576dd4082a72cc176a2865513031c6200df32eebdf77894b2b8f"},
    {"2048", "e3deeb5a2004cc135d0c60d694a06d746a6ffbcc5009e31368d3e2af360f985a"},
    {"2049", "b4467e073bfa567e4a337b8b8a04da641184522ae5bb753584244a1f37696c4c"},
    {"3073", "5795c366f3dd3d823ee2b8bf21724bdd1a0fe378a8616dba2b011c46715125f2"},
    {"5121", "269647e2dd34dd8055e7f39620b006c91d516b658203d5404583575c1e0c545e"},
    {"8193", "67af3328f4c7f02f0d20e2921dd61513170f6151748e2989b3dd4f775c099236"},
  };

  private static final String[][] MIXED = {
    {"1", "7bdcc4c951f17b858dd3098096a6bfc4618d2e712012ea8deda5db2b40207365"},
    {"300", "a4d2df6b99760f8ac8e166f46ab4427e8e987aeef49768283c5061cfceb9372d"},
  };

  @Test
  void aHashedFieldNeedsAKeyAndShowsTheKeyedDigest()
  {
    var session = new Session("ann", "tok-12345678");
    assertThrows(IllegalStateException.class, session::toString);
    assertThrows(IllegalArgumentException.class, () -> LawSpecMasks.setMaskHashKey(new byte[31]));
    LawSpecMasks.setMaskHashKey(
        "whats the Elvish word for friend".getBytes(StandardCharsets.UTF_8));
    for (String[] row : LETTERS)
    {
      String text = "abcdefghijklmnopqrstuvwxyz".repeat(400).substring(0, Integer.parseInt(row[0]));
      assertEquals("hash:" + row[1], LawSpecMasks.maskHash(text));
    }
    for (String[] row : MIXED)
    {
      String text = "a\u00e9\u20ac\uD83D\uDE00".repeat(Integer.parseInt(row[0]));
      assertEquals("hash:" + row[1], LawSpecMasks.maskHash(text));
    }
    String shown = session.toString();
    assertEquals("Session{user=ann, token=" + LawSpecMasks.maskHash("tok-12345678") + "}", shown);
    assertTrue(shown.matches("Session\\{user=ann, token=hash:[0-9a-f]{64}}"), shown);
    assertFalse(shown.contains("tok-12345678"), shown);
    assertEquals(
        "Session{user=ann, token=***}",
        lawspec.definitions.example.Masking.maskedSession(Map.of(), session));
    assertTrue(session.toUnmaskedString().contains("tok-12345678"));
  }
}
