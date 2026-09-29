"""The emitted codec bridge composes the native child shrinker."""

from hypothesis import find, settings
from hypothesis import strategies as st

import codec_generators
import lawspec_data as data
import lawspec_native_generators as native
from lawspec_schema import Named


def test_generic_codec_preserves_child_shrinking():
    source = native.strategy(
        data.make_schema(),
        Named("native.codecs::type::Parcel", [Named("Int8")]),
        64, 64, lambda name: st.integers(1, 100))
    before = codec_generators.samples
    value = find(source, lambda item: item.fields[0] > 60,
                 settings=settings(database=None, derandomize=True))
    assert value.fields[0] == 61
    assert codec_generators.samples > before
