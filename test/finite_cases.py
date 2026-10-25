"""Runtime cover traversal keeps ordered cases and fresh native values."""

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "runtime"))
from lawspec_runtime import finite_cases, register_finite_cases, search_elements  # noqa: E402


def constant(value):
    return lambda _symbols: value


def decode(cover):
    return [
        (index, [factory({}) for factory in values])
        for index, values in finite_cases(cover)
    ]


assert decode([]) == []
assert decode(1) == [(0, [])]
assert decode(2) == [(0, []), (1, [])]
product = [[[0, [constant(False), constant(True)]], [[[1, 125, 127], 1]]]]
assert decode(product) == [
    (0, [False, 125]),
    (1, [False, 126]),
    (2, [False, 127]),
    (3, [True, 125]),
    (4, [True, 126]),
    (5, [True, 127]),
]
dependent = [
    [[0, [constant(0)]], [[[0, [constant(0)]], 1]]],
    [[0, [constant(1)]], [[[1, 0, 1], 1]]],
]
assert decode(dependent) == [(0, [0, 0]), (1, [1, 0]), (2, [1, 1])]
huge = finite_cases([[[1, 0, 2**128], 1]])
assert next(huge)[1][0]({}) == 0
assert next(huge)[1][0]({}) == 1
huge.close()
((_, (factory,)),) = finite_cases([[[0, [lambda _symbols: {"count": 0}]], 1]])
first = factory({})
first["count"] = 1
assert factory({})["count"] == 0

namespace = {}
observations = []


def check(factories, context):
    observations.append(([factory({}) for factory in factories], context))


registered = register_finite_cases(namespace, "test_law_", product, check, "the law")
assert list(namespace) == [f"test_law__boundary_{i}" for i in range(1, 7)]
assert registered == list(namespace.values())
namespace["test_law__boundary_2"]()
namespace["test_law__boundary_6"]()
assert observations == [
    ([False, 126], "the law boundary 2"),
    ([True, 127], "the law boundary 6"),
]
wrapped = []
registered = register_finite_cases(
    {},
    "test_wrapped_",
    1,
    check,
    "wrapped",
    lambda name, run: (wrapped.append(name), run()),
)
registered[0]()
assert wrapped == ["test_wrapped__boundary_1"]
assert observations[-1] == ([], "wrapped boundary 1")

from itertools import product as cartesian_product  # noqa: E402

for length in range(6):
    for codes in cartesian_product([-1, 0, 1], repeat=length):
        for universal in [False, True]:
            decisive = -1 if universal else 1
            expected = decisive if decisive in codes else 0 if 0 in codes else -decisive
            visited = []

            def evaluate(code):
                visited.append(code)
                return code

            assert search_elements(universal, codes, evaluate) == expected
            stop = codes.index(decisive) + 1 if decisive in codes else len(codes)
            assert visited == list(codes[:stop])

try:
    search_elements(False, [2], lambda code: code)
    raise AssertionError("invalid outcome was accepted")
except ValueError:
    pass
try:
    search_elements(False, [False], lambda code: code)
    raise AssertionError("a boolean was accepted as an incomplete outcome")
except ValueError:
    pass
print("finite cover Python conformance passed")
