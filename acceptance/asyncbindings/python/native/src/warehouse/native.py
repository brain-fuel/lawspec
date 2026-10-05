# Application code the warehouse adapters are bound to: some of it
# asynchronous, as a real service client would be.
import asyncio
import threading


def _price(sku):
    return 0 if sku == "free" else len(sku) % 100


async def price_of(sku):
    await asyncio.sleep(0)
    return _price(sku)


def quote_of(sku):
    return _price(sku)


class Shelf:
    """A stock count that several callers may change at once."""

    def __init__(self):
        self._total = 0
        self._lock = threading.Lock()

    async def restock(self, amount):
        await asyncio.sleep(0)
        with self._lock:
            self._total += amount

    async def count(self):
        await asyncio.sleep(0)
        with self._lock:
            return self._total
