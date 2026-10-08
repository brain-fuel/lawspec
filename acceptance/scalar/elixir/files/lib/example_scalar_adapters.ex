# Native Elixir adapters exercise the shared checked scalar bridge.
# ref:DEC-acceptance-with-mutants
defmodule Example.ScalarAdapters do
  def echo_char(value), do: value
  def echo_code_point(value), do: value
  def echo_code_unit(value), do: value
  def echo_bytes(value), do: value
  def echo_complex(value), do: value
  def successor(value), do: value + 1
  def narrow(value), do: value
  def add_decimal(a, b), do: :lawspec_beam_scalar.binary("+", a, b, "Decimal", "Decimal")
  def same_symbol(a, b), do: :lawspec_beam_scalar.equal(a, b)
  def echo_raw(value), do: value
  def echo_presence(value), do: value
  def finish(:ok), do: :ok
  def preserve_big(value), do: value
  def machine_echo(value), do: value
end
