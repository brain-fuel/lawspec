# User-owned LawSpec adapter. Implement these functions.
defmodule Example.ScalarAdapters do
  @spec echo_char(non_neg_integer()) :: non_neg_integer()

  def echo_char(_argument0) do raise "Not implemented: example.scalar_adapters::echoChar" end

  @spec echo_code_point(non_neg_integer()) :: non_neg_integer()

  def echo_code_point(_argument0) do
    raise "Not implemented: example.scalar_adapters::echoCodePoint"
  end

  @spec echo_code_unit(non_neg_integer()) :: non_neg_integer()

  def echo_code_unit(_argument0) do
    raise "Not implemented: example.scalar_adapters::echoCodeUnit"
  end

  @spec echo_bytes(binary()) :: binary()

  def echo_bytes(_argument0) do raise "Not implemented: example.scalar_adapters::echoBytes" end

  @spec echo_complex(:lawspec_beam_scalar.complex()) :: :lawspec_beam_scalar.complex()

  def echo_complex(_argument0) do raise "Not implemented: example.scalar_adapters::echoComplex" end

  @spec successor(-128..127) :: integer()

  def successor(_argument0) do raise "Not implemented: example.scalar_adapters::successor" end

  @spec narrow(-128..127) :: -128..127

  def narrow(_argument0) do raise "Not implemented: example.scalar_adapters::narrow" end

  @spec add_decimal(:lawspec_beam_scalar.decimal(), :lawspec_beam_scalar.decimal()) ::
    :lawspec_beam_scalar.decimal()

  def add_decimal(_argument0, _argument1) do
    raise "Not implemented: example.scalar_adapters::addDecimal"
  end

  @spec same_symbol(:lawspec_beam_scalar.symbol(), :lawspec_beam_scalar.symbol()) :: boolean()

  def same_symbol(_argument0, _argument1) do
    raise "Not implemented: example.scalar_adapters::sameSymbol"
  end

  @spec echo_raw([non_neg_integer()]) :: [non_neg_integer()]

  def echo_raw(_argument0) do raise "Not implemented: example.scalar_adapters::echoRaw" end

  @spec echo_presence(:none | {:some, :null | {:non_null, -128..127}}) ::
    :none | {:some, :null | {:non_null, -128..127}}

  def echo_presence(_argument0) do
    raise "Not implemented: example.scalar_adapters::echoPresence"
  end

  @spec finish(:ok) :: :ok

  def finish(_argument0) do raise "Not implemented: example.scalar_adapters::finish" end

  @spec preserve_big(0..18446744073709551615) :: 0..18446744073709551615

  def preserve_big(_argument0) do raise "Not implemented: example.scalar_adapters::preserveBig" end

  @spec machine_echo(-9223372036854775808..9223372036854775807) ::
    -9223372036854775808..9223372036854775807

  def machine_echo(_argument0) do raise "Not implemented: example.scalar_adapters::machineEcho" end
end
