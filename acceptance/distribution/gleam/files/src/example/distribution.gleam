// ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
import gleam/list
import gleam/option.{None}
import lawspec/data
import lawspec/network
import lawspec/remote
import lawspec/remote/example/distribution as client
import lawspec/actors/example/distribution/tally_actor as tally
import lawspec/actors/example/distribution/tally_actor_remote as remote_tally
import lawspec/mailboxes/example/distribution/ledger
import lawspec/sessions
import lawspec/sessions/example/distribution/doubling
import lawspec/sessions/example/distribution/handoff
import lawspec/sessions/example/distribution/answering
import lawspec/sessions/example/distribution/passing

@external(erlang, "beam_distribution_support", "encoded")
pub fn encoded(text: String, seed: Int, size: Int, count: Int) -> List(String)
@external(erlang, "beam_distribution_support", "round_trips")
pub fn round_trips(text: String, seed: Int, size: Int, count: Int) -> Bool
@external(erlang, "beam_distribution_support", "handshake_agrees")
pub fn handshake_agrees(vector: String) -> Bool
@external(erlang, "beam_distribution_support", "seed")
fn seed(value: Int) -> Int
@external(erlang, "beam_distribution_support", "contains_frame")
fn contains_frame(net: network.MemoryNetwork, bytes: String) -> Bool
@external(erlang, "beam_distribution_support", "with_task")
fn with_task(task: sessions.Task(Nil), body: fn() -> result) -> result

pub fn open_tally(_unit: Nil) -> data.Tally { data.Tally(0) }
pub fn add(state: data.Tally, value: Int) -> data.Pair(Int, data.Tally) {
  let data.Tally(count) = state
  data.Pair(count + value, data.Tally(count + value))
}

pub fn remote_shifted(value: Int) -> Int {
  use net <- network.with_memory(network.MemoryOptions(..network.memory_options(),
    seed: seed(value), loss: 0.2, duplicate: 0.2))
  use here <- network.with_node(network.memory_transport(net, "here"))
  use there <- network.with_node(network.memory_transport(net, "there"))
  remote.serve(there)
  client.shifted(here, network.address(there), value)
}

pub fn remote_adds(value: Int) -> Int {
  use server <- network.with_node(network.tcp("127.0.0.1", 0))
  use caller <- network.with_node(network.tcp("127.0.0.1", 0))
  use actor <- tally.with_actor
  let address = tally.serve(actor, server, "tally")
  let handle = remote_tally.connect(caller, address)
  remote_tally.add(handle, value)
  remote_tally.add(handle, value)
}

pub fn remote_doubling(value: Int) -> Int {
  use server <- network.with_node(network.http("127.0.0.1", 0))
  use caller <- network.with_node(network.http("127.0.0.1", 0))
  let first = doubling.listen(server, "doubling")
  let second = doubling.dial(caller, doubling.address(first))
  let task = doubling.spawn_second(second, double)
  use <- with_task(task)
  answer(first, value)
}
fn double(channel_end: doubling.Second0) -> Nil {
  let #(value, reply) = doubling.second_receive_0(channel_end)
  doubling.second_send_1(reply, 2 * value)
  Nil
}
fn answer(channel_end: doubling.First0, value: Int) -> Int {
  let #(result, _) = channel_end |> doubling.first_send_0(value) |> doubling.first_receive_1
  result
}

pub fn remote_ledger(value: Int) -> Int {
  use server <- network.with_node(network.tcp("127.0.0.1", 0))
  use caller <- network.with_node(network.tcp("127.0.0.1", 0))
  let mailbox = ledger.serve(server, "ledger")
  let sender = ledger.connect(caller, ledger.address(mailbox), 5000)
  ledger.send_remote(sender, value)
  ledger.send_remote(sender, value)
  let total = ledger.receive_value(mailbox) + ledger.receive_value(mailbox)
  let assert None = ledger.receive_within(mailbox, 20000)
  ledger.stop(mailbox)
  total
}

pub fn remote_handoff(value: Int) -> Int {
  use here <- network.with_node(network.tcp("127.0.0.1", 0))
  use there <- network.with_node(network.tcp("127.0.0.1", 0))
  use first, second <- doubling.with_pair
  let task = doubling.spawn_second(second, double)
  use <- with_task(task)
  let giving = handoff.listen(here, "handoff")
  let taking = handoff.dial(there, handoff.address(giving))
  handoff.first_send_0(giving, first)
  let #(channel_end, _) = handoff.second_receive_0(taking)
  answer(channel_end, value)
}

pub fn remote_handoff_onward(value: Int) -> Int {
  use net <- network.with_memory(network.MemoryOptions(..network.memory_options(),
    seed: seed(value), loss: 0.1, duplicate: 0.1, delay_seconds: 0.005))
  use a <- network.with_node(network.memory_transport(net, "a"))
  use b <- network.with_node(network.memory_transport(net, "b"))
  use c <- network.with_node(network.memory_transport(net, "c"))
  use d <- network.with_node(network.memory_transport(net, "d"))
  let first = answering.listen(a, "answering")
  let second = c |> answering.dial(answering.address(first)) |> answering.second_send_0(value)
  let giving_b = passing.listen(a, "to-b")
  let taking_b = passing.dial(b, passing.address(giving_b))
  passing.first_send_0(giving_b, first)
  let #(moved, _) = passing.second_receive_0(taking_b)
  let giving_d = passing.listen(b, "to-d")
  let taking_d = passing.dial(d, passing.address(giving_d))
  passing.first_send_0(giving_d, moved)
  let #(channel_end, _) = passing.second_receive_0(taking_d)
  network.close(a)
  network.close(b)
  let #(input, reply) = answering.first_receive_0(channel_end)
  answering.first_send_1(reply, 2 * input)
  let #(result, _) = answering.second_receive_1(second)
  result
}

pub fn sealed_on_the_wire(value: Int) -> Bool {
  let digest = remote.digest("example.distribution::shifted")
  list.all([False, True], fn(insecure) {
    use net <- network.with_memory(network.MemoryOptions(..network.memory_options(), seed: seed(value), record: True))
    let make = case insecure {
      True -> network.insecure_memory_transport_for_tests
      False -> network.memory_transport
    }
    use here <- network.with_node(make(net, "here"))
    use there <- network.with_node(make(net, "there"))
    remote.serve(there)
    client.shifted(here, network.address(there), value) == value + 1000
      && contains_frame(net, digest) == insecure
  })
}
