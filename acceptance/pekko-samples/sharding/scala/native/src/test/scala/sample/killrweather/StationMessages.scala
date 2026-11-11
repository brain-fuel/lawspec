// LawSpec suite code, not part of the vendored sample: WeatherStation's
// messages carry its own Data, DataType and Function, which no LawSpec codec
// makes, so the binding's message factories make them here, in the sample's
// package, from the handler's arguments. ref:DEC-pekko-sample-suites
package sample.killrweather

import org.apache.pekko.actor.typed.ActorRef

/** Makes WeatherStation's Record and Query messages for LawSpec's checks. */
private[killrweather] object StationMessages {

  /** A temperature reading taken now, in degrees Celsius. */
  def reading(celsius: Short, replyTo: ActorRef[WeatherStation.DataRecorded]): WeatherStation.Command = {
    val now = System.currentTimeMillis()
    WeatherStation.Record(WeatherStation.Data(now, WeatherStation.DataType.Temperature, celsius.toDouble), now, replyTo)
  }

  /** A query for the current temperature, which answers how many readings there are. */
  def temperatures(replyTo: ActorRef[WeatherStation.QueryResult]): WeatherStation.Command =
    WeatherStation.Query(WeatherStation.DataType.Temperature, WeatherStation.Function.Current, replyTo)
}
