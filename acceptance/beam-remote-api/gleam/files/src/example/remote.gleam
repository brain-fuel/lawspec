// ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
import gleam/option.{Some}
import lawspec/data
import lawspec/abilities/example/remote as abilities
import lawspec/network
import lawspec/remote
import lawspec/remote/example/remote as client

@external(erlang, "beam_remote_probe", "with_nodes")
fn with_nodes(body: fn(network.Node, network.Node) -> a) -> a
@external(erlang, "beam_remote_probe", "rejected")
fn rejected(node: network.Node, digest: String) -> Bool

pub fn offset_handler() -> abilities.Offset { abilities.offset(fn(n) { n + 1000 }) }
pub fn native_probe(_unit: Nil) -> Bool {
  use a, b <- with_nodes
  let assert "mem://b/definitions" = remote.serve(b, abilities.offset(fn(n) { n + 40 }))
  let assert 47 = client.shifted(a, "mem://b", 7)
  let assert 48 = client.shifted_with_timeout(a, "mem://b", 1000, 8)
  let parcel = data.Parcel(42, Some("sent"))
  let assert True = client.parcel(a, "mem://b", parcel) == parcel
  let Nil = client.nothing(a, "mem://b", Nil)
  rejected(a, remote.digest("example.remote::shifted"))
}
