# ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
defmodule Example.Remote do
  alias LawSpec.Abilities.Example.Remote.Offset
  alias LawSpec.Remote.Example.Remote, as: Remote
  def offset_handler(), do: %Offset{shift: fn n -> n + 1000 end}
  def native_probe(:ok) do
    :beam_remote_probe.with_nodes(fn a, b ->
      "mem://b/definitions" = LawSpec.Remote.serve(b, %Offset{shift: fn n -> n + 40 end})
      47 = Remote.shifted(a, "mem://b", 7)
      48 = Remote.shifted_with_timeout(a, "mem://b", 1000, 8)
      parcel = %LawSpec.Data.Parcel{count: 42, note: {:just, "sent"}}
      ^parcel = Remote.parcel(a, "mem://b", parcel)
      :ok = Remote.nothing(a, "mem://b", :ok)
      :beam_remote_probe.rejected(a, LawSpec.Remote.digest("example.remote::shifted"))
    end)
  end
end
