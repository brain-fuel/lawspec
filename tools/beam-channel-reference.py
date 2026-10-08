"""Endpoint handoff snapshots from the existing portable network protocol.
ref:DEC-distribution-canonical-wire
"""
import base64
import json
from pathlib import Path
import random
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "runtime"))
import lawspec_runtime as ls


class NoThread:
    def __init__(self, *args, **kwargs):
        pass

    def start(self):
        pass


class Node:
    def __init__(self):
        self.sent = []

    def _send(self, address, kind, payload):
        self.sent.append((address, kind, payload))


random = random.Random(983713)
encode = lambda b: base64.b64encode(b).decode()
cases = []
for i in range(200):
    node = Node()
    with patch.object(ls.threading, "Thread", NoThread):
        end = ls._NetEndpoint(node, [], ls._NO_TYPES, 0, 5)
    end.address = "mem://a/end"
    end._token = "token-" + str(i)
    end._failure = random.choice([None, "the other end gave up", "unreachable λ"])
    end._peer = random.choice([None, "mem://b/end"])
    end._history = [f"mem://former-{j}/end" for j in range(random.randrange(4))]
    end._out, end._expected = random.randrange(10), random.randrange(10)
    body = lambda: b"\x00" + random.randbytes(random.randrange(10))
    unacked = [(n, body()) for n in range(end._out) if random.randrange(2)]
    if random.randrange(2):
        unacked.append((-1, b"hello"))
    early = [(n, body()) for n in range(end._expected + 1, end._expected + 5) if random.randrange(2)]
    received = [body() for _ in range(random.randrange(5))]
    if random.randrange(4) == 0:
        received.append(b"\x01")
    end._unacked = {n: [None, 0, 0, b] for n, b in unacked}
    end._early = dict(early)
    for b in received:
        end._inbox.put((None, b))
    request = ls.wire_encode(ls._NO_TYPES, ["text"], end._token) + ls.wire_encode(ls._NO_TYPES, ["text"], "mem://c/end")
    end._give(request)
    [(to, kind, payload)] = node.sent
    assert to == "mem://c/end" and kind == "state"
    cases.append({"token": end._token, "failure": end._failure or "", "peer": end._peer or "",
                  "history": end._history, "out": end._out, "expected": end._expected,
                  "unacked": [[n, encode(b)] for n, b in unacked],
                  "early": [[n, encode(b)] for n, b in early],
                  "received": [encode(b) for b in received], "state": encode(payload)})
Path(sys.argv[1]).write_text(json.dumps(cases, ensure_ascii=False) + "\n")
