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
| A mailbox | `node.mailbox(name, type)` | `node.remote_mailbox(address, type).send(value)` |

- **Actors.** A call waits for the reply. If no reply comes within the
  timeout (5 seconds by default), it fails with `Unreachable`. A lost call
  is sent again, and the node that receives it runs it **once** and answers
  each copy with the same reply.
- **Channels** keep their protocol's order. Each value travels in a
  numbered frame that is sent again until acknowledged, so loss,
  duplication and reordering are repaired. If the other end is silent for
  the deadline (5 seconds), the channel fails like a failed process: a
  receive raises `PeerFailed` ([failures](scenarios.md#when-a-process-fails)).
  A protocol whose steps send channel ends runs only within one process
  for now.
- **Checked definitions** are evaluated **by content hash**: the hash of
  the definition and everything it uses. Two nodes agree on a hash exactly
  when they hold the same definition, so a node never runs a different
  version of the code by mistake.
- **Mailboxes** are best effort: a value sent may be lost.

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
