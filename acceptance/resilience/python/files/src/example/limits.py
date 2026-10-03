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
