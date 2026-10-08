# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Resilience do
  @spec runtime_exponential_delay(integer(), integer(), integer()) :: integer()

  def runtime_exponential_delay(_argument0, _argument1, _argument2) do
    raise "Not implemented: example.resilience::runtimeExponentialDelay"
  end

  @spec runtime_linear_delay(integer(), integer(), integer()) :: integer()

  def runtime_linear_delay(_argument0, _argument1, _argument2) do
    raise "Not implemented: example.resilience::runtimeLinearDelay"
  end

  @spec runtime_fibonacci_delay(integer(), integer()) :: integer()

  def runtime_fibonacci_delay(_argument0, _argument1) do
    raise "Not implemented: example.resilience::runtimeFibonacciDelay"
  end

  @spec split_mix(0..18446744073709551615, -2147483648..2147483647) :: [0..18446744073709551615]

  def split_mix(_argument0, _argument1) do raise "Not implemented: example.resilience::splitMix" end

  @spec full_jitter(0..18446744073709551615, integer()) :: integer()

  def full_jitter(_argument0, _argument1) do
    raise "Not implemented: example.resilience::fullJitter"
  end

  @spec retried_waits(-2147483648..2147483647) :: [integer()]

  def retried_waits(_argument0) do raise "Not implemented: example.resilience::retriedWaits" end

  @spec rejected_waits(-2147483648..2147483647) :: [integer()]

  def rejected_waits(_argument0) do raise "Not implemented: example.resilience::rejectedWaits" end

  @spec limited_at([integer()]) :: [boolean()]

  def limited_at(_argument0) do raise "Not implemented: example.resilience::limitedAt" end

  @spec compensations_for(-9223372036854775808..9223372036854775807) :: [binary()]

  def compensations_for(_argument0) do
    raise "Not implemented: example.resilience::compensationsFor"
  end

  @spec quote_timed_out(-9223372036854775808..9223372036854775807) :: boolean()

  def quote_timed_out(_argument0) do raise "Not implemented: example.resilience::quoteTimedOut" end

  @spec quote_hedged(-9223372036854775808..9223372036854775807) :: boolean()

  def quote_hedged(_argument0) do raise "Not implemented: example.resilience::quoteHedged" end
end
