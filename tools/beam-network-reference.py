"""Canonical frames and packet fault decisions from the portable runtime.

Suppress real timer/thread creation while recording the existing transport's
random draws. The BEAM tests independently exercise the delayed deliveries.
ref:DEC-distribution-canonical-wire ref:DEC-portable-seeded-generation
"""
import base64
import json
from pathlib import Path
import random
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "runtime"))
import lawspec_runtime as ls


random = random.Random(273109)
frames = []
for i in range(200):
    kind = random.choice(["chan", "ack", "mail", "call", "reply", "take", "state", "moved", "moved-ack", "eval"])
    to = random.choice(["", "mailbox", "definitions", "node-42", "reply/λ/👋"])
    source = random.choice(["mem://a", "tcp://127.0.0.1:7000", "http://[::1]:8000", "mem://β"])
    ident = random.choice([0, 1, 2**64 - 1, random.randrange(2**64)])
    payload = random.randbytes(random.randrange(255))
    encoded = ls._frame_encode(kind, to, source, ident, payload)
    assert ls._frame_decode(encoded) == [kind, to, source, ident, payload]
    frames.append({"kind": kind, "to": to, "source": source, "id": ident,
                   "payload": base64.b64encode(payload).decode(), "frame": base64.b64encode(encoded).decode()})
Path(sys.argv[1]).write_text(json.dumps(frames, ensure_ascii=False) + "\n")


class Draws:
    def __init__(self, seed):
        self.random = ls.SplitMix64(seed)
        self.draws = []

    def below(self, bound):
        value = self.random.below(bound)
        self.draws.append((bound, value))
        return value


class NoThread:
    def __init__(self, *args, **kwargs):
        pass

    def start(self):
        pass


faults = []
for seed in (0, 1, -1, 701, 2**64 + 5):
    for loss, duplicate in ((0, 0), (1, 0), (0, 1), (0.1, 0.1), (0.8, 0.7)):
        network = ls.MemoryNetwork(seed=seed, loss=loss, duplicate=duplicate, record=True)
        network._nodes = {"mem://a": lambda _: None, "mem://b": lambda _: None}
        draws = network._random = Draws(seed)
        trace = []
        with patch.object(ls.threading, "Thread", NoThread), patch.object(ls.threading, "Timer", NoThread):
            for i in range(30):
                if i % 7 == 0:
                    network.partition(["a"], ["b"])
                elif i % 7 == 1:
                    network.heal()
                to = "mem://missing" if i % 11 == 0 else "mem://b"
                draws.draws = []
                try:
                    network._send("mem://a", to, str(i).encode())
                    slots = [n for bound, n in draws.draws if bound == 1001]
                    outcome = "sent" if slots else "partitioned" if network._groups is not None else "lost"
                except ls.Unreachable:
                    slots, outcome = [], "unreachable"
                trace.append({"outcome": outcome, "slots": slots})
        assert len(network.recorded) == 30
        faults.append({"seed": seed, "loss": loss, "duplicate": duplicate, "trace": trace})
Path(sys.argv[2]).write_text(json.dumps(faults) + "\n")
