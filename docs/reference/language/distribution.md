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
stack can stand in for these three.

### Testing with faults

`MemoryNetwork(seed, loss, duplicate, delay)` connects nodes in one
process. Each frame may be lost or duplicated, and is delayed by up to
`delay` seconds, so frames can overtake each other. `partition(...)` cuts
groups of nodes off from each other until `heal()`. The faults come from the
seed, so they repeat.

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
- **Checked definitions** are evaluated **by content hash**: the hash of
  the definition and everything it uses. Two nodes agree on a hash exactly
  when they hold the same definition, so a node never runs a different
  version of the code by mistake.
- **Mailboxes.** A send to a mailbox on another node waits until the
  mailbox has the message. A lost send is sent again, and the mailbox takes
  it once.

## Moving a channel end

Sending a channel end to another node works for both kinds of end, in
different ways.

**An end between nodes moves.** Say node B holds an end whose other end
(its **peer**) is on node C, and B sends it to node D. Then:

1. B sends D a text address for the end: the end's address on B, then
   `?take=` and a one-time token, such as
   `tcp://10.0.0.5:7000/end-12?take=9f2c...`.
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
