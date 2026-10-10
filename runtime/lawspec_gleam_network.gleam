// Nodes and memory networks follow their creating process. Scoped constructors
// join their owned processes on return, including when the body raises.
// ref:DEC-distribution-canonical-wire ref:DEC-idiomatic-generated-types
pub type Node
pub type MemoryNetwork
pub type Transport
pub type Identity
pub type Options

pub type MemoryOptions {
  MemoryOptions(seed: Int, loss: Float, duplicate: Float, delay_seconds: Float, record: Bool)
}

pub fn memory_options() -> MemoryOptions {
  MemoryOptions(seed: 0, loss: 0.0, duplicate: 0.0, delay_seconds: 0.0, record: False)
}

@external(erlang, "lawspec_network", "options")
pub fn options() -> Options
@external(erlang, "lawspec_network", "with_identity")
pub fn with_identity(options: Options, identity: Identity) -> Options
@external(erlang, "lawspec_network", "with_trusted")
pub fn with_trusted(options: Options, fingerprints: List(String)) -> Options
@external(erlang, "lawspec_network", "trust_on_first_use")
pub fn trust_on_first_use(options: Options) -> Options
@external(erlang, "lawspec_network", "new_identity")
pub fn new_identity() -> Identity
@external(erlang, "lawspec_network", "identity_from_seed")
pub fn identity_from_seed(seed: BitArray) -> Identity
@external(erlang, "lawspec_network", "public_key")
pub fn public_key(identity: Identity) -> BitArray
@external(erlang, "lawspec_network", "fingerprint")
pub fn fingerprint(identity: Identity) -> String

@external(erlang, "lawspec_network", "tcp")
pub fn tcp(host: String, port: Int) -> Transport
@external(erlang, "lawspec_network", "http")
pub fn http(host: String, port: Int) -> Transport
@external(erlang, "lawspec_network", "advertise")
pub fn advertise(transport: Transport, host: String) -> Transport
@external(erlang, "lawspec_network", "memory")
pub fn memory(options: MemoryOptions) -> MemoryNetwork
@external(erlang, "lawspec_network", "with_memory")
pub fn with_memory(options: MemoryOptions, body: fn(MemoryNetwork) -> a) -> a
@external(erlang, "lawspec_network", "close_memory")
fn close_memory_native(network: MemoryNetwork) -> Nil
pub fn close_memory(network: MemoryNetwork) -> Nil { close_memory_native(network) Nil }
@external(erlang, "lawspec_network", "memory_transport")
pub fn memory_transport(network: MemoryNetwork, name: String) -> Transport
@external(erlang, "lawspec_network", "insecure_memory_transport_for_tests")
pub fn insecure_memory_transport_for_tests(network: MemoryNetwork, name: String) -> Transport
@external(erlang, "lawspec_network", "partition")
fn partition_native(network: MemoryNetwork, groups: List(List(String))) -> Nil
pub fn partition(network: MemoryNetwork, groups: List(List(String))) -> Nil {
  partition_native(network, groups)
  Nil
}
@external(erlang, "lawspec_network", "heal")
fn heal_native(network: MemoryNetwork) -> Nil
pub fn heal(network: MemoryNetwork) -> Nil { heal_native(network) Nil }
@external(erlang, "lawspec_network", "recorded")
pub fn recorded(network: MemoryNetwork) -> List(BitArray)

@external(erlang, "lawspec_network", "open")
pub fn open(transport: Transport) -> Node
@external(erlang, "lawspec_network", "open")
pub fn open_with_options(transport: Transport, options: Options) -> Node
@external(erlang, "lawspec_network", "with_node")
pub fn with_node(transport: Transport, body: fn(Node) -> a) -> a
@external(erlang, "lawspec_network", "with_node")
pub fn with_node_options(transport: Transport, options: Options, body: fn(Node) -> a) -> a
@external(erlang, "lawspec_network", "close")
fn close_native(node: Node) -> Nil
pub fn close(node: Node) -> Nil { close_native(node) Nil }
@external(erlang, "lawspec_network", "address")
pub fn address(node: Node) -> String
@external(erlang, "lawspec_network", "node_fingerprint")
pub fn node_fingerprint(node: Node) -> String
