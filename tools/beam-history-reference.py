"""Scenario vector clocks checked against the existing portable runtime.

Completed calls can carry another process's clock through a message. The
BEAM history search must preserve exactly those causal dependencies.
ref:DEC-sessions-by-construction ref:DEC-stateful-models-linearizability
"""
import json
from pathlib import Path
import random
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "runtime"))
import lawspec_runtime as ls


spec = """(machine counter shared) (start (indices) (arguments (unit)))
(command add (arguments (int UInt8 0 255)) (state 0) (unit false) (when false)
 (needs) (shifts) (key none) (restart false))
(command read (arguments) (state 0) (unit false) (when false)
 (needs) (shifts) (key none) (restart false))
(command clear (arguments) (state 0) (unit true) (when false)
 (needs) (shifts) (key none) (restart false))
(abstract false) (invariants) (perkey false) (actor false) (consistency linearizable)"""
pair = lambda a, b: ls.DataValue("Pair::Pair", (a, b))
refs = [lambda _, n, s: pair(n + s, n + s), lambda _, s: pair(s, s), lambda _, s: 0]
model = ls.Model(spec, (lambda _, u: 0, lambda _, u: 0), [(f, f, None) for f in refs])
random = random.Random(910052)
vectors = []
for mode in ("linearizable", "sequential", "causal", "eventual"):
    model.consistency = mode
    for _ in range(250):
        initial = random.randrange(3)
        state, tick = initial, 0
        clocks = {p: {} for p in ("A", "B", "C")}
        events = []
        for _ in range(random.randrange(9)):
            process = random.choice(list(clocks))
            clock = clocks[process]
            if events and random.randrange(2):
                # A send/receive can carry a previous call's entire clock.
                for p, n in random.choice(events)[7].items():
                    clock[p] = max(clock.get(p, 0), n)
            clock[process] = clock.get(process, 0) + 1
            called = dict(clock)
            index = random.randrange(3)
            args = [random.randrange(3)] if index == 0 else []
            state, result = ls._step_model(model.commands[index], {}, args, state)
            if result is ls.UNIT:
                result = 0  # Unit command results are deliberately not compared.
            if random.randrange(4) == 0:
                result = random.randrange(4)
            clock[process] += 1
            events.append((index, args, result, tick, tick + 1, process, called, dict(clock)))
            tick += 2
        final = random.choice([None, state, state, random.randrange(4)])
        # The collector need not retain call order.
        random.shuffle(events)
        history = [(model.commands[i], *event[1:]) for event in events for i in [event[0]]]
        expected = ls._linearizes_history(model, {}, history, initial, final, None)
        vectors.append({"mode": mode, "events": events, "initial": initial,
                        "final": final, "consistent": expected})
Path(sys.argv[1]).write_text(json.dumps(vectors) + "\n")
