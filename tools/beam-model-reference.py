"""Model runs and ordered shrink candidates from the portable Python runtime.

The BEAM generator consumes precisely the same seed stream, even when a
reference rejects a command or an actor run injects crashes.
ref:DEC-portable-seeded-generation ref:DEC-stateful-models-linearizability
"""
import json
from pathlib import Path
import random as host_random
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "runtime"))
import lawspec_runtime as ls


def command(name, arguments="", position=0, unit=False, needs="", shifts="", restart=False):
    boolean = lambda b: str(b).lower()
    return (f"(command {name} (arguments {arguments}) (state {position}) "
            f"(unit {boolean(unit)}) (when false) (needs {needs}) (shifts {shifts}) "
            f"(key none) (restart {boolean(restart)}))")


def model(kind):
    pair = lambda a, b: ls.DataValue("Pair::Pair", (a, b))
    if kind == "stack":
        commands = [
            command("push", "(int Int8 -128 127)", 1, True, "(atleast 0)", "(by 1)"),
            command("pop", needs="(atleast 1)", shifts="(by -1)"),
            command("clear", unit=True, needs="(atleast 0)", shifts="(to 0)")]
        refs = [lambda _, n, s: [n] + s, lambda _, s: pair(s[0], s[1:]), lambda _, s: []]
        callbacks = [(f, f, None) for f in refs]
        start = lambda _, u: []
        indices, sharing = "0", "linear"
    else:
        commands = [command("add", "(int UInt8 0 255)"), command("read"), command("close", unit=True)]
        refs = [lambda _, n, s: pair(n + s, n + s), lambda _, s: pair(s, s), lambda _, s: 0]
        callbacks = [(f, f, None) for f in refs]
        start = lambda _, u: 0
        indices, sharing = "", "shared"
        if kind == "actor":
            commands.append(command("reopen", unit=True, restart=True))
            callbacks.append((lambda _, s: s + 10, lambda _, s: s + 10, None))
        elif kind == "guarded":
            def guarded(_, n, s):
                if n >= 5:
                    raise ValueError("reference domain")
                return pair(n + s, n + s)
            commands = commands[:1]
            callbacks = [(guarded, guarded, lambda _, s: s < 20)]
    spec = (f"(machine sample {sharing}) (start (indices {indices}) (arguments (unit))) "
            + " ".join(commands) + f" (abstract false) (invariants) (perkey false) "
            f"(actor {str(kind == 'actor').lower()}) (consistency linearizable)")
    return ls.Model(spec, (start, start), callbacks)


vectors = []
for kind in ("stack", "counter", "actor", "guarded"):
    m = model(kind)
    for seed in (0, 1, 701, -1, 2**64 + 5):
        for length in (0, 1, 20):
            for size in (0, 1, 8):
                random = ls.SplitMix64(seed)
                run = ls._generate_run(m, random, length, size, crashes=True)
                vectors.append({"kind": kind, "seed": seed, "length": length, "size": size,
                                "end": random.state, "run": ls._describe_run(m, run),
                                "shrinks": [ls._describe_run(m, r) for r in ls._shrink_candidates(m, run)]})
Path(sys.argv[1]).write_text(json.dumps(vectors, ensure_ascii=False) + "\n")

parallel = []
for kind in ("counter", "actor", "guarded"):
    m = model(kind)
    for seed in (0, 1, 701, -1, 2**64 + 5):
        for size in (1, 8):
            for threads in (2, 3):
                for length in (2, 5):
                    random = ls.SplitMix64(seed)
                    case = ls._generate_parallel(m, random, size, threads, length)
                    prefix, branches = case
                    candidates = []
                    args, steps = prefix
                    for k in range(len(steps)):
                        candidates.append(((args, steps[:k] + steps[k + 1:]), branches))
                    for i, branch in enumerate(branches):
                        for k in range(len(branch)):
                            changed = [b if j != i else b[:k] + b[k + 1:] for j, b in enumerate(branches)]
                            candidates.append((prefix, changed))
                    for i, branch in enumerate(branches):
                        for k, (index, args) in enumerate(branch):
                            for a, (descriptor, arg) in enumerate(zip(m.commands[index].arguments, args)):
                                for smaller in m.values.shrink(descriptor, arg):
                                    step = (index, args[:a] + [smaller] + args[a + 1:])
                                    changed = [b if j != i else b[:k] + [step] + b[k + 1:]
                                               for j, b in enumerate(branches)]
                                    candidates.append((prefix, changed))
                    parallel.append({"kind": kind, "seed": seed, "size": size, "threads": threads,
                                     "length": length, "end": random.state,
                                     "run": ls._describe_parallel(m, case),
                                     "shrinks": [ls._describe_parallel(m, c) for c in candidates]})
Path(sys.argv[2]).write_text(json.dumps(parallel, ensure_ascii=False) + "\n")

histories = []
m = model("counter")
random = host_random.Random(91527)
for mode in ("linearizable", "sequential", "causal", "eventual"):
    m.consistency = mode
    for _ in range(200):
        branches = [[(index, [random.randint(0, 2)] if index == 0 else [])
                     for index in [random.randrange(3) for _ in range(random.randrange(4))]]
                    for _ in range(3)]
        # Interleave call/return events while keeping each branch's order.
        times = [[[] for _ in b] for b in branches]
        positions = [0] * len(branches)
        tick = 0
        while choices := [i for i, b in enumerate(branches) if positions[i] < 2 * len(b)]:
            i = random.choice(choices)
            times[i][positions[i] // 2].append(tick)
            tick += 1
            positions[i] += 1
        events = [[(a, b, random.randrange(4)) for a, b in branch] for branch in times]
        initial, final = random.randrange(3), random.choice([None, 0, 1, 2, 3, 4])
        result = ls._linearize(m, {}, branches, events, initial,
                               lambda state: final is None or state == final)
        histories.append({"mode": mode, "branches": branches, "history": events,
                          "initial": initial, "final": final, "consistent": result})
Path(sys.argv[3]).write_text(json.dumps(histories) + "\n")
