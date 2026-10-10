// ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
import gleam/option.{Some}
import lawspec/data
import lawspec/abilities/example/remote as abilities
import lawspec/network
import lawspec/remote
import lawspec/remote/example/remote as client

@external(erlang, "beam_remote_probe", "sealed")
fn sealed(net: network.MemoryNetwork) -> Bool
@external(erlang, "beam_remote_probe", "rejected")
fn rejected(node: network.Node, digest: String) -> Bool

pub fn offset_handler() -> abilities.Offset { abilities.offset(fn(n) { n + 1000 }) }
pub fn native_probe(_unit: Nil) -> Bool {
  let identity = network.identity_from_seed(<<0:size(256)>>)
  let other = network.new_identity()
  let options = network.options() |> network.with_identity(identity) |> network.with_trusted([network.fingerprint(other)])
  let other_options = network.options() |> network.with_identity(other) |> network.with_trusted([network.fingerprint(identity)])
  use net <- network.with_memory(network.MemoryOptions(seed: 922, loss: 0.15, duplicate: 0.3, delay_seconds: 0.001, record: True))
  use a <- network.with_node_options(network.memory_transport(net, "a"), options)
  use b <- network.with_node_options(network.memory_transport(net, "b"), other_options)
  let assert True = network.node_fingerprint(a) == network.fingerprint(identity)
  let assert "mem://b" = network.address(b)
  let assert "mem://b/definitions" = remote.serve(b, abilities.offset(fn(n) { n + 40 }))
  let assert 47 = client.shifted(a, "mem://b", 7)
  let assert 48 = client.shifted_with_timeout(a, "mem://b", 1000, 8)
  let parcel = data.Parcel(42, Some("sent"))
  let assert True = client.parcel(a, "mem://b", parcel) == parcel
  let Nil = client.nothing(a, "mem://b", Nil)
  rejected(a, remote.digest("example.remote::shifted")) && sealed(net)
}
