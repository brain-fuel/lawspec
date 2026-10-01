# User-owned LawSpec adapter.
import asyncio


def _price(sku):
    return 0 if sku == "free" else len(sku) % 100


async def price(value0):
    await asyncio.sleep(0)
    return _price(value0)


async def stock(value0):
    await asyncio.sleep(0)
    return len(value0)


def quote(value0):
    return _price(value0)
