# User-owned LawSpec adapter.
import lawspec_data as data
import lawspec_schema as _schema


def audit(value0):
    return True


def waitlist(value0):
    if isinstance(value0, data.SignupErrorUnavailable):
        return _schema.Right(data.Account("waitlist", 18, 0))
    return _schema.Left(value0)


def checkName(value0):
    if len(value0.name) == 0:
        return _schema.Left(data.SignupErrorMissingName())
    return _schema.Right(value0)


def checkAge(value0):
    if value0.age < 18:
        return _schema.Left("too young")
    return _schema.Right(value0)


def openAccount(value0):
    if value0.name == "taken":
        return _schema.Left(data.SignupErrorUnavailable())
    return _schema.Right(data.Account(value0.name, value0.age, 1))


# Each check records when it fails, so approvalErrors can tell completion
# order from declaration order.
_finished = []


async def checkStock(value0):
    """Order -1's stock check takes 400ms; a negative order has no stock."""
    import asyncio
    if value0.number == -1:
        await asyncio.sleep(0.4)
    if value0.number < 0:
        _finished.append("no stock")
        return _schema.Left("no stock")
    return _schema.Right(value0)


async def checkCredit(value0):
    """Order -1's credit check takes 250ms; a negative order has no credit."""
    import asyncio
    if value0.number == -1:
        await asyncio.sleep(0.25)
    if value0.number < 0:
        _finished.append("no credit")
        return _schema.Left("no credit")
    return _schema.Right(value0)
