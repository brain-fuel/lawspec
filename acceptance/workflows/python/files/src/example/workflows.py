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
