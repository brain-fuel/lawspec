---
id: lawspec.reference.language.distribution
kind: reference
title: Distribution
---
# Distribution

Programs built with LawSpec can run as several **nodes** that talk over a
network. Nodes may run on different targets, for example a Python node and a
Go node. Their actors, channels and checked definitions are reachable at
addresses, and values cross the network in one encoding, the same bytes on
every target.

## Nodes and transports

A node sends and receives through a **transport**:

| Transport | Address | Use |
| --- | --- | --- |
| In memory | `mem://name` | Nodes in one process, with faults for testing |
| TCP | `tcp://host:port` | Frames over TCP, each a 4-byte length then the frame |
| HTTP | `http://host:port` | Each frame is the body of a `POST /lawspec` |

Everything a node offers has an address: the node's address, `/`, and a
name, such as `tcp://10.0.0.5:7000/tally`.

In Python:

```python
import lawspec_runtime as ls

node = ls.Node(ls.TcpTransport(port=7000))   # port 0 picks a free port
print(node.address)                          # tcp://127.0.0.1:7000
```

A transport is a small interface (start, send, close), so another network
stack can stand in for these three. Transports are the handlers of the
`Network` ability (see [existing features as
abilities](abilities-mapping.md#distribution)); a node secures every one of
them the same way (see [security](#security)).

### Testing with faults

`MemoryNetwork(seed, loss, duplicate, delay)` connects nodes in one
process. Each frame may be lost or duplicated, and is delayed by up to
`delay` seconds, so frames can overtake each other. `partition(...)` cuts
groups of nodes off from each other until `heal()`. The faults come from the
seed, so they repeat.

### BEAM node APIs

Erlang uses `lawspec_network`, Elixir uses `LawSpec.Network`, and Gleam
imports `lawspec/network`. Add `import lawspec.network` to the LawSpec
source to include the secure transport and its C/OpenSSL seed bridge.

| Operation | Erlang / Elixir | Gleam |
| --- | --- | --- |
| TCP or HTTP transport | `tcp(host, port)`, `http(host, port)` | Same |
| Open a node | `open(transport, options)` | `open_with_options(transport, options)` |
| Scoped node | `with_node(transport, options, body)` | `with_node_options(transport, options, body)` |
| Use configured defaults | `open(transport)`, `with_node(transport, body)` | Same |
| Node address or fingerprint | `address(node)`, `node_fingerprint(node)` | Same |
| Close a node | `close(node)` | Same |

Port `0` chooses an available port. Use an unbracketed IPv6 host such as
`"::1"`; the returned address includes brackets. `advertise(transport,
host)` sets the hostname that peers use when the listening host is a
wildcard address. Nodes belong to their creating process. Scoped
constructors close and join their transport workers when the body returns
or raises; `open` keeps the node until `close` or its creator exits.

For example, in Elixir:

```elixir
alias LawSpec.Network

Network.with_node(Network.tcp("127.0.0.1", 7000), fn node ->
  IO.puts(Network.address(node))
  # Serve actors, definitions, mailboxes or channels here.
end)
```

Build options with `options()`, `with_identity(options, identity)` and
`with_trusted(options, fingerprints)`. `identity_from_seed(bytes)` accepts
the shared 32-byte seed; `new_identity()` creates one. `fingerprint(identity)`
and `public_key(identity)` return its hexadecimal fingerprint and public
key. Unspecified options use the shared configuration described below.
An empty trusted list rejects every peer. `trust_on_first_use(options)`
explicitly selects the default address-pinning behavior.

For memory transports, use `with_memory(options, body)` and
`memory_transport(network, name)`. Erlang accepts an options map and Elixir
accepts a map or keyword list (`seed`, `loss`, `duplicate`, `delay`,
`record`). Gleam provides `memory_options()` and the `MemoryOptions` record,
whose delay field is `delay_seconds`. `partition`, `heal`, and `recorded`
operate on that network. `insecure_memory_transport_for_tests(network,
name)` is the explicit test transport that also works without the import.

The BEAM TCP/HTTP transports accept records up to 64 MiB. Their I/O runs in
owned workers with bounded queues and five-second connection/read/write
timeouts. HTTP uses one `POST /lawspec` per connection and responds with
`204`; the peer's reply arrives through its own node listener.

## What a node can offer

| Offer | Here | From another node |
| --- | --- | --- |
| An actor | `AccountActor.start().serve(node, "account")` | `AccountActor.connect(node, address)`, whose methods are the handlers |
| A protocol's channel | `Doubling.listen(node, "doubling")` gives the first end | `Doubling.dial(node, address)` gives the second end |
| Checked definitions | `lawspec_remote.serve(node)` | `lawspec_remote.evaluate(node, address, name, args...)` |
| A mailbox | `JobsMailbox.serve(node, "jobs")` | `JobsMailbox.connect(node, address).send(value)` |

- **Actors.** A call waits for the reply. If no reply comes within the
  timeout (5 seconds by default), it fails with `Unreachable`. A lost call
  is sent again, and the node that receives it runs it **once** and answers
  each copy with the same reply.
- **Channels** keep their protocol's order. Each value travels in a
  numbered frame that is sent again until acknowledged, so loss,
  duplication and reordering are repaired. If the other end is silent for
  the deadline (5 seconds), the channel fails like a failed process: a
  receive raises `PeerFailed` ([failures](scenarios.md#when-a-process-fails)).
- **Channel ends between nodes.** An end sent over a channel to another
  node keeps working there, with its order and failures unchanged. An end
  that already talks across the network **moves** to the new node; a local
  end stays put and the sending node relays its conversation (see
  [moving a channel end](#moving-a-channel-end)).
- **Checked definitions** are evaluated **by content hash**: the SHA3-256
  hash (FIPS 202) of the definition and everything it uses, written with
  its algorithm, as `sha3-256:` then 64 hexadecimal digits. Two nodes agree
  on a hash exactly when they hold the same definition, so a node never runs
  a different version of the code by mistake.
- **Mailboxes.** A send to a mailbox on another node waits until the
  mailbox has the message. A lost send is sent again, and the mailbox takes
  it once.

### BEAM definition APIs

Erlang, Elixir and Gleam generate typed remote functions for checked
definitions whose arguments and results have wire encodings. For a
definition `shifted` in `example.remote`, the client modules are:

| Target | Module |
| --- | --- |
| Erlang | `lawspec_remote_example_remote` |
| Elixir | `LawSpec.Remote.Example.Remote` |
| Gleam | `lawspec/remote/example/remote` |

Call `shifted(node, address, value)`, or
`shifted_with_timeout(node, address, timeout_milliseconds, value)`. The
default timeout is 5000 milliseconds. Arguments and results use the
target's native types, including its representation of `Unit` and data
constructors. `address` is the node address, such as `tcp://host:7000`;
the client appends `/definitions`.

The root module (`lawspec_remote`, `LawSpec.Remote`, or `lawspec/remote`)
provides `serve(node, handlers...)` and `digest(qualified_name)`. The
generated `serve` signature lists the native ability interfaces required
by the definitions. Each request invokes the checked definition using
those server interfaces. The client supplies only the definition's value
arguments. A request for an unknown content hash is rejected before a
definition runs.

## Moving a channel end

Sending a channel end to another node works for both kinds of end, in
different ways.

**An end between nodes moves.** Say node B holds an end whose other end
(its **peer**) is on node C, and B sends it to node D. Then:

1. B sends D a text address for the end: the end's address on B, then
   `?take=` and a one-time token, such as
   `tcp://10.0.0.5:7000/end-12?take=9f2c...`. The token is 32 bytes from
   the operating system's secure generator, as 64 hexadecimal digits, as
   `SecureRandom`'s `secureToken` gives, on every target.
2. D asks B for the end with a `take` frame carrying the token. B hands
   over the end's state in a `state` frame: where the peer is, the next
   sequence numbers each way, the values it sent that were not yet
   acknowledged, and the values it received that were not yet used.
3. From then on B forwards anything that still arrives for the end to D.
4. D tells the peer on C the end's new address with a `moved` frame. C
   answers with `moved-ack`, and sends to D directly from then on.

The receive on D returns once C has answered, so B may then stop: the
conversation between C and D no longer passes through B. Each frame is
sent again until it is answered, so loss, duplication and reordering do not
matter, and an end can move again from D to another node in the same way.

**A local end stays and is relayed.** An end whose peer is on the same node
(made by `open()`) cannot move without its peer, so the sending node
listens on a fresh address, sends that address, and passes each step
between the end and the node that dials it.

**When a move cannot finish.** If the old node does not hand the end over
within the deadline (5 seconds), the end fails on its new node like a
failed peer: its next receive raises `PeerFailed`. If the peer does not
answer the `moved` frame within the deadline, the receive returns anyway
and the old node keeps forwarding, as a relay would; the new node keeps
telling the peer, and the old node drops out once the peer answers.

## The wire encoding

A value is encoded by its type, so no type tags are sent:

| Type | Bytes |
| --- | --- |
| Integers | the integer, zigzag-encoded (0, -1, 1, -2… become 0, 1, 2, 3…), then LEB128 (7 bits per byte, low first) |
| `Bool` | `0` or `1` |
| `Text` | its UTF-8 length in LEB128, then the UTF-8 |
| `Unit` | nothing |
| `List a` | the count in LEB128, then each item |
| `Maybe a` | `0`, or `1` then the value |
| `Either a b` | `0` then the left value, or `1` then the right |
| A data type | the constructor's position in LEB128, then its fields |

Every target's encoding is checked against the same vectors, in the
[distribution example](../../../examples/specs/distribution.lawspec).

### Frames

Nodes exchange **frames**. A frame is five values in this encoding: its
kind (`Text`), the name it is for on the receiving node (`Text`), the
sending node's address (`Text`), a request number (`UInt64`, 0 for none),
and its payload (bytes: the length in LEB128, then the bytes).

A channel uses these kinds. A *number* is an integer (as `Int64`), and an
*address* is a full address such as `mem://b/end-3`.

| Kind | Payload | Meaning |
| --- | --- | --- |
| `chan` | number, sender's end address, body | One step's value (body `0` then the value), giving up (body `1`), or the dialer's hello (number -1, body `hello`) |
| `ack` | number | The `chan` frame with this number arrived |
| `take` | token, new end address | Asks for an end offered as `<address>?take=<token>` |
| `state` | token, failure, peer, former addresses, next number to send, next number expected, unacknowledged, early, received | The end's state, for the new end. Failure and peer are `Text`, empty when there is none; former addresses are a `List Text`; unacknowledged and early are lists of a number then its body (bytes), each list a count then its items; received is a list of bodies |
| `moved` | former addresses, new address | The peer moved: its old addresses (`List Text`) and where it is now |
| `moved-ack` | new address | The receiver now sends to the new address |

An end that receives `moved` switches to the new address when its peer's
address is one of the former ones (or it has none yet), and answers
`moved-ack` whenever it now sends to the new address.

## Security

A program that makes nodes imports `lawspec.network`:

```lawspec fragment
import lawspec.network
```

The import brings the **secure network handler**, written beside the
runtime, with the crypto libraries it needs (see
[built-in abilities](builtins.md#dependencies-of-generated-projects)). A
program without it does without those libraries, and can make a node only
on the in-memory transport made for tests; its scenarios' network runs use
that transport. Making any other node fails, saying to add the import.
Python, JavaScript, TypeScript, Java, Kotlin and Go find the module when a
node is made; BEAM nodes do this automatically too. In Rust and Haskell,
call `lawspec_network::install()` or
`LawSpecNetwork.install` once before making nodes (the generated tests do).

The network is then secure on every transport and every target, and nodes on
different targets interoperate:

- each node has an **identity**, an ML-DSA-65 key pair (FIPS 204);
- before two nodes exchange frames, they run a **handshake**: a signed
  ML-KEM-768 key exchange (FIPS 203);
- every frame then crosses **sealed** with AES-256-GCM (NIST SP 800-38D),
  under a key derived with SHAKE256 (FIPS 202).

Nothing in `lawspec.json` turns this off. The one exception is made for tests
of the frame layer: `MemoryNetwork(...).insecure_transport_for_tests(name)`
(`insecureTransportForTests` on the other targets) gives an in-memory
transport whose node skips the handshake. Only an in-memory network makes
one, and its type says what it is.

### Identities

A node's identity is the 32-byte seed of its ML-DSA-65 key (FIPS 204,
`ML-DSA.KeyGen_internal`); its **fingerprint** is the SHA3-256 of the
verifying key, in hexadecimal. By default each node makes a fresh identity
from the operating system's secure generator. A node made with an identity
uses it (`Node(transport, identity=NodeIdentity(seed))` in Python), and one
made with `trusted` fingerprints talks only to those peers. Otherwise a node
accepts any peer, but each address keeps the first identity it showed: a
later handshake from that address with another key is refused.

`lawspec.json` binds both, per target, in `nativeBindings`:

```json
"nativeBindings": {
  "network": {"identity": "keys/node.seed", "trusted": "keys/peers.txt"}
}
```

`identity` names a file holding the seed as 64 hexadecimal digits, and
`trusted` a file of fingerprints, one per line, both relative to the
project. The compiler writes them to `lawspec-network.conf` (lines
`identity <file>` and `trusted <file>`), which a node reads when it is made
without an identity: from the file `LAWSPEC_NETWORK_CONF` names, or the first
`lawspec-network.conf` in the working directory or a directory above it.

### The handshake

The node that sends first to a peer it has no session with queues its
frames, then sends a **hello**; the peer answers with a **welcome**. A hello
is sent again every 100 ms until the welcome comes, for up to 5 seconds, and
a peer answers a repeated hello with the same welcome, so loss, duplication
and reordering do not matter.

Every handshake and data value is a **record**: the bytes `4C 53 01` (`LS`,
version 1), a kind byte, then its fields. A field written `w(x)` is the
length of `x` in LEB128, then `x`.

| Record | Kind | Fields |
| --- | --- | --- |
| hello | `01` | the hello body *H*, then `w(signature)` |
| welcome | `02` | the welcome body *W*, then `w(signature)` |
| data | `03` | `w(session)`, the direction (one byte), `w(sealed)` |

- *H* = `w(session) w(address) w(vk) w(ek)`: a fresh 16-byte session id, the
  sender's node address (UTF-8), its ML-DSA-65 verifying key (1952 bytes) and
  a fresh ML-KEM-768 encapsulation key (1184 bytes). The signature is
  ML-DSA-65's over `"lawspec-handshake-v1-hello"` followed by *H*, with an
  empty context.
- *W* = `w(session) w(address) w(vk) w(ct) w(SHA3-256(H))`: the same session,
  the answering node's address and verifying key, the ML-KEM-768 ciphertext
  encapsulated to *ek* (1088 bytes), and the hash of the hello it answers.
  The signature is over `"lawspec-handshake-v1-welcome"` followed by *W*.
- Each side checks the other's signature and identity. The node that sent
  the hello also checks that the welcome comes from the address it sent to,
  names its session, and answers its hello.
- Both derive the session key: the first 32 bytes of
  SHAKE256(*ss* ‖ `"lawspec-session-v1"` ‖ SHA3-256(*H*) ‖ SHA3-256(*W*)),
  where *ss* is the ML-KEM shared secret.

### Sealed frames

A data record carries one [frame](#frames). *sealed* is a fresh 12-byte
nonce from the secure generator, then the AES-256-GCM ciphertext and 16-byte
tag of the frame, with associated data `"lawspec-frame-v1"` ‖ session ‖
direction. The direction is `00` from the node that sent the hello and `01`
from the other, so a record cannot be reflected back to its sender. A record
that does not open is dropped, and the layers above send again, as they do
for a lost frame.

A node sends on the session it began, or on one its peer began once a frame
has arrived on it (the peer then surely has the key). The session keys live
as long as the nodes.

Every target checks the same **handshake vector** (from
`dev/handshake-vector.py`): from fixed seeds and a ciphertext, the hashes of
*H* and *W*, the session key and a sealed frame, byte for byte. The
distribution example's law `` the secure handshake agrees across targets ``
runs it, and `` frames cross sealed by default `` checks that a frame's
contents never show on an in-memory network's wire unless its nodes use the
test-only transport.

### What it protects

The handshake authenticates each node to the other, gives each session a
fresh key (forward secrecy within a node's lifetime, as the ML-KEM key is
made for each handshake), and seals every frame against reading and
tampering, with algorithms chosen to resist quantum computers. A frame
passed on by a relay (a [moved channel end](#moving-a-channel-end)) is
sealed again on each hop, so each hop is authenticated, not the frame's
original sender.

## Testing distributed behaviour

- **Scenarios** run over a faulty network: one run in three puts each
  channel's two ends on two nodes of a `MemoryNetwork` that loses,
  duplicates and delays frames. Every run must still agree with the model
  ([scenarios](scenarios.md#running-scenarios)).
- **Consistency.** A shared model can say how its histories must agree
  with the model: linearizable (the default), sequential, causal or
  eventual ([models](models.md#consistency)).
- **Laws** can call adapters that start nodes and talk across them, as the
  distribution example does with in-memory, TCP and HTTP transports.

## Evidence

`lawspec evidence` lists each scenario's network runs as property-tested,
with its other runs, and each model's consistency.

## References

- NIST FIPS 202, *SHA-3 Standard: Permutation-Based Hash and Extendable-Output
  Functions*, 2015.
- NIST FIPS 203, *Module-Lattice-Based Key-Encapsulation Mechanism Standard*,
  2024.
- NIST FIPS 204, *Module-Lattice-Based Digital Signature Standard*, 2024.
- NIST SP 800-38D, *Recommendation for Block Cipher Modes of Operation:
  Galois/Counter Mode (GCM) and GMAC*, 2007.
