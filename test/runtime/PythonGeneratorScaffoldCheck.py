"""An implemented generic scaffold retains child and container shrinkers."""

from hypothesis import find
from hypothesis import strategies as st

import lawspec_data as data
import lawspec_generators
import lawspec_native_generators
import lawspec_schema as schema


def test_list_factory_composes_the_bound_element_strategy():
    before = lawspec_generators.list_factories
    source = lawspec_native_generators.strategy(
        data.make_schema(), schema.Named("List", [schema.Named("Int8")]),
        64, 64, lambda name: st.nothing())
    assert lawspec_generators.list_factories > before
    result = find(source, lambda values: len(values) >= 2)
    assert result == [6, 6]
