# User-owned LawSpec adapter: an account's handlers, run inside an actor.
import lawspec_data as data


def openAccount(value0):
    return data.Account(0)


def deposit(value0, value1):
    after = value0.balance + value1
    return data.Pair(after, data.Account(after))


def withdrawAll(value0):
    return data.Pair(value0.balance, data.Account(0))


def balance(value0):
    return data.Pair(value0.balance, value0)


def close(value0):
    return data.Account(0)


def depositTwice(value0):
    import threading

    from lawspec_actors import AccountActor

    account = AccountActor.start()
    callers = [threading.Thread(target=account.deposit, args=(value0,)) for _ in range(2)]
    for caller in callers:
        caller.start()
    for caller in callers:
        caller.join()
    total = account.balance()
    account.stop()
    return total
