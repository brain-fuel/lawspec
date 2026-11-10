# User-owned LawSpec adapter: a tab's handlers, run inside an actor.
import lawspec_data as data


def openTab(value0):
    return data.Tab(0)


def add(value0, value1):
    after = value0.total + value1
    return data.Pair(after, data.Tab(after))


def total(value0):
    return data.Pair(value0.total, value0)


def keepsTotal(value0):
    from lawspec_actors import BarSupervisor

    bar = BarSupervisor.start()
    bar.tab.add(value0)
    bar.tab.crash()
    total = bar.tab.total()
    bar.stop()
    return total
