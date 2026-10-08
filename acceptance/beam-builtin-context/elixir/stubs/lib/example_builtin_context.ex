# User-owned LawSpec adapter. Implement these functions.
defmodule Example.BuiltinContext do
  @spec native_probe(:ok) :: boolean()

  def native_probe(_argument0) do raise "Not implemented: example.builtin_context::nativeProbe" end
end
