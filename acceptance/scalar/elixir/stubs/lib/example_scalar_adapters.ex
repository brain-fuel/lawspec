# User-owned LawSpec adapter. Implement these functions.
defmodule Example.ScalarAdapters do
  @spec echo_char(non_neg_integer()) :: non_neg_integer()

  def echo_char(_char) do
    raise "Not implemented: example.scalar_adapters::echoChar"
  end

  @spec echo_code_point(non_neg_integer()) :: non_neg_integer()

  def echo_code_point(_code_point) do
    raise "Not implemented: example.scalar_adapters::echoCodePoint"
  end

  @spec echo_code_unit(non_neg_integer()) :: non_neg_integer()

  def echo_code_unit(_code_unit16) do
    raise "Not implemented: example.scalar_adapters::echoCodeUnit"
  end

  @spec echo_bytes(binary()) :: binary()

  def echo_bytes(_bytes) do
    raise "Not implemented: example.scalar_adapters::echoBytes"
  end

  @spec echo_complex(:lawspec_beam_scalar.complex()) :: :lawspec_beam_scalar.complex()

  def echo_complex(_complex64) do
    raise "Not implemented: example.scalar_adapters::echoComplex"
  end

  @spec successor(-128..127) :: integer()

  def successor(_int8) do
    raise "Not implemented: example.scalar_adapters::successor"
  end

  @spec narrow(-128..127) :: -128..127

  def narrow(_int8) do
    raise "Not implemented: example.scalar_adapters::narrow"
  end

  @spec add_decimal(:lawspec_beam_scalar.decimal(), :lawspec_beam_scalar.decimal()) ::
          :lawspec_beam_scalar.decimal()

  def add_decimal(_decimal, _decimal_2) do
    raise "Not implemented: example.scalar_adapters::addDecimal"
  end

  @spec same_symbol(:lawspec_beam_scalar.symbol(), :lawspec_beam_scalar.symbol()) :: boolean()

  def same_symbol(_symbol, _symbol_2) do
    raise "Not implemented: example.scalar_adapters::sameSymbol"
  end

  @spec echo_raw([non_neg_integer()]) :: [non_neg_integer()]

  def echo_raw(_utf16_text) do
    raise "Not implemented: example.scalar_adapters::echoRaw"
  end

  @spec echo_presence(:none | {:some, :null | {:non_null, -128..127}}) ::
          :none | {:some, :null | {:non_null, -128..127}}

  def echo_presence(_optional_nullable_int8) do
    raise "Not implemented: example.scalar_adapters::echoPresence"
  end

  @spec finish(:ok) :: :ok

  def finish(_unit) do
    raise "Not implemented: example.scalar_adapters::finish"
  end

  @spec preserve_big(0..18_446_744_073_709_551_615) :: 0..18_446_744_073_709_551_615

  def preserve_big(_u_int64) do
    raise "Not implemented: example.scalar_adapters::preserveBig"
  end

  @spec machine_echo(-9_223_372_036_854_775_808..9_223_372_036_854_775_807) ::
          -9_223_372_036_854_775_808..9_223_372_036_854_775_807

  def machine_echo(_int_size) do
    raise "Not implemented: example.scalar_adapters::machineEcho"
  end
end
