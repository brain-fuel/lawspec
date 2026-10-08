defmodule Example.Clocks do
  def steady_clock do
    inner = Lawspec.Time.clock_handler()
    readings = :lawspec_beam_effects.native_cell(0)
    %{now: fn ->
      _count = :lawspec_beam_handler.call(readings, fn n -> {n + 1, n + 1} end)
      %LawSpec.Data.Instant{value: micros} = inner.now.()
      %LawSpec.Data.Instant{value: micros}
    end, sleep: inner.sleep}
  end
end
