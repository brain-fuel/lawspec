// LawSpec suite code, not part of the vendored sample: WeatherStation's
// messages carry its own Data, DataType and Function, which no LawSpec codec
// makes, so the binding's message factories make them here, in the sample's
// package, from the handler's arguments. ref:DEC-pekko-sample-suites
package sample.killrweather;

import org.apache.pekko.actor.typed.ActorRef;

/** Makes WeatherStation's Record and Query messages for LawSpec's checks. */
final class StationMessages
{
  private StationMessages()
  {
  }

  /** A temperature reading taken now, in degrees Celsius. */
  static WeatherStation.Command reading(short celsius,
      ActorRef<WeatherStation.DataRecorded> replyTo)
  {
    long now = System.currentTimeMillis();
    return new WeatherStation.Record(
        new WeatherStation.Data(now, WeatherStation.DataType.Temperature, celsius), now, replyTo);
  }

  /** A query for the current temperature, which answers how many readings there are. */
  static WeatherStation.Command temperatures(ActorRef<WeatherStation.QueryResult> replyTo)
  {
    return new WeatherStation.Query(WeatherStation.DataType.Temperature,
        WeatherStation.Function.Current, replyTo);
  }
}
