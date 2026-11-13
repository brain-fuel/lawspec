package lawspec.logging;

import ch.qos.logback.classic.pattern.ClassicConverter;
import ch.qos.logback.classic.spi.ILoggingEvent;
import lawspec.runtime.LawSpecMasked;
import org.slf4j.helpers.MessageFormatter;

/**
 * A Logback message converter that renders every argument through {@link LawSpecMasked}.
 *
 * <p>Use it in place of {@code %msg}, so that the pattern cannot print an argument any other way:
 *
 * <pre>{@code
 * <conversionRule conversionWord="maskedMsg"
 *     converterClass="lawspec.logging.LawSpecMaskedConverter" />
 * <pattern>%d %-5level %logger - %maskedMsg%n</pattern>
 * }</pre>
 *
 * <p>This file is generated outside the compiled sources, because it needs Logback and SLF4J on
 * the class path. Add its directory to the build of a project that has them.
 */
public final class LawSpecMaskedConverter extends ClassicConverter
{
  @Override
  public String convert(ILoggingEvent event)
  {
    Object[] arguments = event.getArgumentArray();
    if (arguments == null || arguments.length == 0)
    {
      return event.getFormattedMessage();
    }
    var masked = new Object[arguments.length];
    for (int i = 0; i < arguments.length; i++)
    {
      Object argument = arguments[i];
      masked[i] = argument instanceof Throwable ? argument : LawSpecMasked.render(argument);
    }
    return MessageFormatter.arrayFormat(event.getMessage(), masked).getMessage();
  }
}
