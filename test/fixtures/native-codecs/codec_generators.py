"""Native Hypothesis factories retain their child shrinkers."""

from hypothesis import strategies as st

import codec_domain as domain


samples = 0


def parcels(elements):
    def wrap(item):
        global samples
        samples += 1
        return domain.Parcel(item)

    return elements.map(wrap)


def positives():
    return st.integers(1, 100).map(domain.Positive)
