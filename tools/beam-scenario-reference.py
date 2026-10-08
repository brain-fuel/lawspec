"""Portable scenario schedules, including the crashed process and boundary.

Only branches outside an or-else are crash candidates; structural identities
are stable even when an or-else contains its own par.
ref:DEC-portable-seeded-generation ref:DEC-sessions-by-construction
"""
import json
from pathlib import Path
import random
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "runtime"))
import lawspec_runtime as ls


def identities(acts, found):
    for act in acts:
        if act[0] == "par":
            for branch in act[1:]:
                found[id(branch)] = len(found) + 1
                identities(branch[1:], found)
        elif act[0] == "receiveor":
            identities(act[3][1:], found)
    return found


random = random.Random(825570)


def process(depth):
    acts = []
    for _ in range(random.randrange(5)):
        kind = random.randrange(5) if depth else 0
        if kind == 1:
            acts.append("(par " + " ".join(process(depth - 1) for _ in range(random.randrange(1, 4))) + ")")
        elif kind == 2:
            acts.append("(receiveor c value " + process(depth - 1) + ")")
        else:
            acts.append("(call read value)")
    return "(process " + " ".join(acts) + ")"


vectors = []
for _ in range(40):
    spec = '(scenario "a scenario" counter) (channels c) (mailboxes) ' + process(3)
    forms = ls.read_descriptor(spec)
    body = next(f for f in forms if f[0] == "process")[1:]
    names = identities(body, {})
    branches = ls._scenario_processes(body, [])
    for seed in (0, 1, -1, 701, 2**64 + 5):
        stream = ls.SplitMix64(seed ^ 0x2545F4914F6CDD1D)
        cases = []
        for run in range(30):
            shake = stream.next()
            victim = None
            if branches:
                choose = ls.SplitMix64(shake ^ 0xC3A5C85C97CB3127)
                branch = branches[choose.below(len(branches))]
                victim = [names[branch], choose.below(ls._branch_length(body, branch) + 1)]
            cases.append({"shake": shake, "network": run % 3 == 1, "crash": run % 3 == 2, "victim": victim})
        vectors.append({"spec": spec, "seed": seed, "cases": cases})
Path(sys.argv[1]).write_text(json.dumps(vectors) + "\n")
