package example;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
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
import lawspec.runtime.LawSpecMasked;
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
}
