"""Framework-independent conversion hooks using public model operations."""

import codec_domain as domain
import lawspec_data as data
from lawspec_schema import Just, Nothing


def to_parcel(value, convert):
    return domain.Parcel(convert(value.item))


def from_parcel(value, convert):
    return data.Parcel(convert(value.unpack()))


def to_chain(value, convert):
    items = []
    while isinstance(value, data.ChainMore):
        items.append(convert(value.item))
        if isinstance(value.tail, Nothing):
            return domain.FlatChain(items, False)
        value = value.tail.value
    return domain.FlatChain(items, True)


def from_chain(value, convert):
    items, ended = value.unpack()
    tail = Just(data.ChainStop()) if ended else Nothing()
    for item in reversed(items):
        tail = Just(data.ChainMore(convert(item), tail))
    if isinstance(tail, Nothing):
        raise ValueError("empty chain without Stop has no logical value")
    return tail.value


def to_positive(value):
    return domain.Positive(value.value)


def from_positive(value):
    return data.Positive(value.unpack())
