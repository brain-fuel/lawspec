"""Descriptor replay vectors from the existing portable Python runtime.

The new BEAM runtime must reproduce the same model runs, shrinks and wire
bytes. These vectors complement the scalar checks against Haskell Core.
ref:DEC-portable-seeded-generation ref:DEC-distribution-canonical-wire
"""
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "runtime"))
import lawspec_runtime as ls

descriptors = [
    "(int Int8 -128 127)", "(int UInt64 0 18446744073709551615)",
    "(int Integer _ _)", "(int Integer _ -1000001)",
    "(int Integer 1000001 _)", "(bool)", "(text)", "(unit)",
    "(list (int Int32 -2147483648 2147483647))",
    "(maybe (list (text)))", "(either (bool) (list (unit)))",
    "(data Tree (ctor Tree::Leaf (int Int8 -128 127)) "
    "(ctor Tree::Fork (ref Tree) (ref Tree))) (ref Tree)",
    '(data Record (ctor "Record::two words" (text) (bool))) (ref Record)',
    "(data A (ctor A::Empty) (ctor A::More (ref B))) "
    "(data B (ctor B::Value (int Int8 -128 127))) (list (ref A))",
]
vectors = []
for descriptor in descriptors:
    values, shape = ls.values_from(descriptor)
    for seed in (0, 1, 701, -1, 2**64 + 5):
        for size in (0, 1, 8):
            random = ls.SplitMix64(seed)
            samples = [values.generate(shape, random, size) for _ in range(16)]
            vectors.append({
                "descriptor": descriptor, "seed": seed, "size": size,
                "expected": [
                    {"text": ls.render(value), "wire": ls.wire_encode(values, shape, value).hex()}
                    for value in samples],
                "state": random.state,
                "shrunk": [ls.render(v) for v in values.shrink(shape, samples[0])],
            })
Path(sys.argv[1]).write_text(json.dumps(vectors, ensure_ascii=False) + "\n")
