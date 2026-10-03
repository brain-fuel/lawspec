# User-owned LawSpec adapter.
import lawspec_schema as _schema


def admitTicket(value0):
    return _schema.Right(value0)


def reserveSeat(value0):
    return _schema.Right(value0)


def chargeCard(value0):
    if value0.number < 0:
        return _schema.Left("declined")
    return _schema.Right(value0)


def releaseSeat(value0):
    return True


async def fetchQuote(value0):
    import asyncio
    if value0.number == -1:
        await asyncio.sleep(0.6)
    return _schema.Right(value0)


_quotes = [0]


def resetQuotes():
    _quotes[0] = 0


async def hedgeQuote(value0):
    """Ticket -2's first quote (and every other one after) stalls."""
    import asyncio
    if value0.number == -2:
        _quotes[0] += 1
        if _quotes[0] % 2 == 1:
            await asyncio.sleep(0.6)
    return _schema.Right(value0)
