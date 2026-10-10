# ref:REQ-harness-units
defmodule Example.Sequencing do
  def pause(n), do: :beam_schedule_support.pause(n)
end
