# ref:REQ-harness-units
defmodule Example.Status do
  def ordinary(flag), do: :beam_status_support.record("ordinary", flag)
  def skipped(n), do: :beam_status_support.forbidden(n)
  def property_bug(n), do: :beam_status_support.property_bug(n)
  def example_bug(n), do: :beam_status_support.example_bug(n)
  def finite_bug(flag), do: :beam_status_support.finite_bug(flag)
  def scored_bug(n), do: :beam_status_support.scored_bug(n)
  def open_guard(unit), do: :beam_status_support.forbidden(unit)
  def close_guard(guard), do: :beam_status_support.forbidden(guard)
  def guard_live(guard), do: :beam_status_support.forbidden(guard)
end
