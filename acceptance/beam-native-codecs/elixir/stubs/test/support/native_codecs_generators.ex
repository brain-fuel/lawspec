# User-owned LawSpec adapter. Implement these functions.
defmodule Native.CodecsGenerators do
  @spec parcels(StreamData.t(a0)) :: StreamData.t(Native.Codecs.Parcel.t(a0)) when a0: term()

  def parcels(_child0) do raise("Implement generator for native.codecs::type::Parcel") end

  @spec positives() :: StreamData.t(Native.Codecs.Positive.t())

  def positives() do raise("Implement generator for native.codecs::type::Positive") end
end
