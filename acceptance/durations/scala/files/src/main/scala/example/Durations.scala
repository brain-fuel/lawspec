// User-owned LawSpec adapter. A Duration is a scala.concurrent.duration.FiniteDuration.
package example

import scala.concurrent.duration.{Duration, FiniteDuration}

object Durations {
  // (lawspec.time::type::Duration -> (lawspec.time::type::Duration ->
  // lawspec.time::type::Duration))
  def remaining(
    value0: scala.concurrent.duration.FiniteDuration,
    value1: scala.concurrent.duration.FiniteDuration,
  ): scala.concurrent.duration.FiniteDuration =
    if (value1 >= value0) Duration.Zero else value0 - value1
}
