"""Framework-independent conversion hooks using public model operations."""

import codec_domain as domain
import lawspec_data as data
from lawspec_schema import Absent, Present


def to_parcel(value, convert):
    return domain.Parcel(convert(value.item))


def from_parcel(value, convert):
    return data.Parcel(convert(value.unpack()))


def to_chain(value, convert):
    items = []
    while isinstance(value, data.ChainMore):
        items.append(convert(value.item))
        if isinstance(value.tail, Absent):
            return domain.FlatChain(items, False)
        value = value.tail.value
    return domain.FlatChain(items, True)


def from_chain(value, convert):
    items, ended = value.unpack()
    tail = Present(data.ChainStop()) if ended else Absent()
    for item in reversed(items):
        tail = Present(data.ChainMore(convert(item), tail))
    if isinstance(tail, Absent):
        raise ValueError("empty chain without Stop has no logical value")
    return tail.value


def to_positive(value):
    return domain.Positive(value.value)


def from_positive(value):
    return data.Positive(value.unpack())
