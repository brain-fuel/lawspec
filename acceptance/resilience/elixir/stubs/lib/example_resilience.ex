# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Resilience do
  @spec runtime_exponential_delay(integer(), integer(), integer()) :: integer()

  def runtime_exponential_delay(_integer, _integer_2, _integer_3) do
    raise "Not implemented: example.resilience::runtimeExponentialDelay"
  end

  @spec runtime_linear_delay(integer(), integer(), integer()) :: integer()

  def runtime_linear_delay(_integer, _integer_2, _integer_3) do
    raise "Not implemented: example.resilience::runtimeLinearDelay"
  end

  @spec runtime_fibonacci_delay(integer(), integer()) :: integer()

  def runtime_fibonacci_delay(_integer, _integer_2) do
    raise "Not implemented: example.resilience::runtimeFibonacciDelay"
  end

  @spec split_mix(0..18_446_744_073_709_551_615, -2_147_483_648..2_147_483_647) :: [
          0..18_446_744_073_709_551_615
        ]

  def split_mix(_u_int64, _int32) do
    raise "Not implemented: example.resilience::splitMix"
  end

  @spec full_jitter(0..18_446_744_073_709_551_615, integer()) :: integer()

  def full_jitter(_u_int64, _integer) do
    raise "Not implemented: example.resilience::fullJitter"
  end

  @spec retried_waits(-2_147_483_648..2_147_483_647) :: [integer()]

  def retried_waits(_int32) do
    raise "Not implemented: example.resilience::retriedWaits"
  end

  @spec rejected_waits(-2_147_483_648..2_147_483_647) :: [integer()]

  def rejected_waits(_int32) do
    raise "Not implemented: example.resilience::rejectedWaits"
  end

  @spec limited_at([integer()]) :: [boolean()]

  def limited_at(_list_integer) do
    raise "Not implemented: example.resilience::limitedAt"
  end

  @spec compensations_for(-9_223_372_036_854_775_808..9_223_372_036_854_775_807) :: [binary()]

  def compensations_for(_int64) do
    raise "Not implemented: example.resilience::compensationsFor"
  end

  @spec quote_timed_out(-9_223_372_036_854_775_808..9_223_372_036_854_775_807) :: boolean()

  def quote_timed_out(_int64) do
    raise "Not implemented: example.resilience::quoteTimedOut"
  end

  @spec quote_hedged(-9_223_372_036_854_775_808..9_223_372_036_854_775_807) :: boolean()

  def quote_hedged(_int64) do
    raise "Not implemented: example.resilience::quoteHedged"
  end
end
