# ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
defmodule Example.Remote do
  alias LawSpec.Abilities.Example.Remote.Offset
  alias LawSpec.Remote.Example.Remote, as: Remote
  alias LawSpec.Network
  def offset_handler(), do: %Offset{shift: fn n -> n + 1000 end}
  def native_probe(:ok) do
    identity = Network.identity_from_seed(<<0::256>>)
    other = Network.new_identity()
    options = Network.options() |> Network.with_identity(identity) |> Network.with_trusted([Network.fingerprint(other)])
    other_options = Network.options() |> Network.with_identity(other) |> Network.with_trusted([Network.fingerprint(identity)])
    Network.with_memory([record: true, seed: 922, loss: 0.15, duplicate: 0.3, delay: 0.001], fn net ->
     Network.with_node(Network.memory_transport(net, "a"), options, fn a ->
      Network.with_node(Network.memory_transport(net, "b"), other_options, fn b ->
      fingerprint = Network.fingerprint(identity)
      ^fingerprint = Network.node_fingerprint(a)
      "mem://b" = Network.address(b)
      "mem://b/definitions" = LawSpec.Remote.serve(b, %Offset{shift: fn n -> n + 40 end})
      47 = Remote.shifted(a, "mem://b", 7)
      48 = Remote.shifted_with_timeout(a, "mem://b", 1000, 8)
      parcel = %LawSpec.Data.Parcel{count: 42, note: {:just, "sent"}}
      ^parcel = Remote.parcel(a, "mem://b", parcel)
      :ok = Remote.nothing(a, "mem://b", :ok)
      :beam_remote_probe.rejected(a, LawSpec.Remote.digest("example.remote::shifted")) and :beam_remote_probe.sealed(net)
      end)
     end)
    end)
  end
end
