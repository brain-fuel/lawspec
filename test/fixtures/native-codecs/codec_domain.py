"""Application-owned models with private storage and public accessors."""


class Parcel[T]:
    __slots__ = ("__item",)

    def __init__(self, item: T):
        self.__item = item

    def unpack(self) -> T:
        return self.__item


class FlatChain[T]:
    __slots__ = ("__items", "__ended")

    def __init__(self, items, ended: bool):
        self.__items = tuple(items)
        self.__ended = ended

    def unpack(self):
        return self.__items, self.__ended


class Positive:
    __slots__ = ("__value",)

    def __init__(self, value: int):
        self.__value = value

    def unpack(self) -> int:
        return self.__value


def copy[T](value: T) -> T:
    return value
