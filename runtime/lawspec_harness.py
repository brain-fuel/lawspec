# The harness plane at run time (see docs/reference/language/harness.md):
# how a law's tests run, never what the law means. Generated tests call it
# for strategies (frequency, such that, bind), adequacy (cover, classify,
# label), run metadata (skip, known failing, timeout, repeat, retry flaky,
# order random) and benchmarks.
#
# Statistics go to standard output, and, when LAWSPEC_STATS names a
# directory, to one JSON file per test there, which lawspec test reads.
import json
import os
import random
import threading
import time
import warnings

from hypothesis import strategies as st

_cases = {}


class HarnessError(AssertionError):
    """A harness requirement failed: a strategy or an adequacy check."""


def _record(name, entry):
    directory = os.environ.get("LAWSPEC_STATS")
    if not directory:
        return
    os.makedirs(directory, exist_ok=True)
    safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in name)
    with open(os.path.join(directory, safe + ".json"), "w", encoding="utf-8") as out:
        json.dump(entry, out, sort_keys=True)


# Strategies. Each draws through Hypothesis, so failures shrink.

# A choice among n: a wide integer, reduced, so every example is new to
# Hypothesis (which never repeats one) and the weights hold; it still shrinks
# toward the first choice.
def _choice(data, n):
    return data.draw(st.integers(min_value=0, max_value=2 ** 32 - 1)) % n


def draw_frequency(data, alternatives):
    total = sum(weight for weight, _ in alternatives)
    pick = _choice(data, total)
    for weight, draw in alternatives:
        if pick < weight:
            return draw()
        pick -= weight
    return alternatives[-1][1]()


def draw_one_of(data, values):
    return values[_choice(data, len(values))]()


def draw_such_that(draw, predicate, limit, strategy):
    for _ in range(limit + 1):
        value = draw()
        if predicate(value):
            return value
    raise HarnessError(
        f"the strategy {strategy} discarded more than {limit} values; "
        "draw closer to what `such that` keeps, or allow more discards")


def check_drawn(strategy, name, holds, value):
    """A drawn value must satisfy its input's refinements: a strategy may
    only produce values the law is about."""
    if not holds(value):
        raise HarnessError(
            f"the strategy {strategy} produced {value!r} for {name}, "
            "which is outside the input's refinement; a strategy may only "
            "produce values of its type")
    return value


# Adequacy: what the generated cases covered.

def target(score, law):
    """target maximize: steer generation toward cases that score higher."""
    import hypothesis
    hypothesis.target(float(score), label=law)


def observe(law, covers=(), classes=(), labels=()):
    stats = _cases.setdefault(law, {"cases": 0, "cover": {}, "classes": {}, "labels": {}})
    stats["cases"] += 1
    for label, holds in covers:
        stats["cover"][label] = stats["cover"].get(label, 0) + (1 if holds else 0)
    for label, holds in classes:
        if holds:
            stats["classes"][label] = stats["classes"].get(label, 0) + 1
    for value in labels:
        key = str(value)
        stats["labels"][key] = stats["labels"].get(key, 0) + 1


def _adequacy(law, covers):
    stats = _cases.pop(law, {"cases": 0, "cover": {}, "classes": {}, "labels": {}})
    cases = stats["cases"]
    results = []
    for percent, label in covers:
        hits = stats["cover"].get(label, 0)
        observed = 100.0 * hits / cases if cases else 0.0
        results.append({"label": label, "required": percent, "observed": round(observed, 2), "met": cases > 0 and observed >= percent})
    report = {"law": law, "cases": cases, "cover": results,
              "classes": stats["classes"], "labels": stats["labels"]}
    lines = [f"{law}: {cases} generated case(s)"]
    for r in results:
        lines.append(f"  cover {r['required']}% \"{r['label']}\": {r['observed']}%" + ("" if r["met"] else " (not met)"))
    for label, count in sorted(stats["classes"].items()):
        lines.append(f"  {label}: {100.0 * count / cases if cases else 0:.1f}%")
    for label, count in sorted(stats["labels"].items(), key=lambda kv: -kv[1]):
        lines.append(f"  label {label}: {100.0 * count / cases if cases else 0:.1f}%")
    if len(lines) > 1:
        print("\n".join(lines))
    return report


# Run metadata.

def _with_timeout(test, milliseconds, law):
    if milliseconds is None:
        return test()
    outcome = {}

    def run():
        try:
            test()
        except BaseException as error:  # noqa: BLE001 - reported below
            outcome["error"] = error
    worker = threading.Thread(target=run, daemon=True)
    worker.start()
    worker.join(milliseconds / 1000)
    if worker.is_alive():
        raise HarnessError(f"{law} took longer than its timeout of {milliseconds} ms")
    if "error" in outcome:
        raise outcome["error"]


def run(law, name, test, timeout=None, repeat=1, retries=0, covers=(), observed=False):
    """Run one generated test of a law under its harness settings."""
    attempts = 0
    flaky = False
    while True:
        attempts += 1
        try:
            for _ in range(repeat):
                _cases.pop(law, None)
                _with_timeout(test, timeout, law)
                report = _adequacy(law, covers) if observed else None
                if report is not None:
                    unmet = [r for r in report["cover"] if not r["met"]]
                    if unmet:
                        _record(name, {**report, "test": name, "outcome": "failed"})
                        raise HarnessError("; ".join(
                            f"{law}: cover {r['required']}% \"{r['label']}\" was not met "
                            f"({r['observed']}% of {report['cases']} generated cases)" for r in unmet))
            break
        except HarnessError:
            raise
        except BaseException:
            if attempts > retries:
                _record(name, {"law": law, "test": name, "outcome": "failed", "attempts": attempts})
                raise
            flaky = True
    entry = {"law": law, "test": name, "outcome": "flaky" if flaky else "passed", "attempts": attempts}
    if observed and report is not None:
        entry.update(report)
    _record(name, entry)
    if flaky:
        warnings.warn(f"{law} is flaky: it failed, then passed on attempt {attempts}")


def skip(law, reason):
    import pytest
    _record(law, {"law": law, "outcome": "skipped", "reason": reason})
    pytest.skip(f"{law}: {reason}")


def known_failing(law, name, reason, tests):
    """A known-failing law's tests must fail. One that passes is reported:
    the harness should no longer say it is known to fail."""
    import pytest
    for test in tests:
        try:
            test()
        except BaseException as error:  # noqa: BLE001 - the expected failure
            _record(name, {"law": law, "test": name, "outcome": "known-failing", "reason": reason})
            pytest.xfail(f"{law} is known to fail ({reason}): {type(error).__name__}")
    _record(name, {"law": law, "test": name, "outcome": "known-failing-passed", "reason": reason})
    raise HarnessError(
        f"{law} is marked known failing ({reason}), but it passes; "
        "remove `known failing` from its harness")


def shuffle_tests(namespace, names):
    """order random: run these tests in an order chosen by the run's seed."""
    seed = os.environ.get("LAWSPEC_SEED")
    order = list(names)
    random.Random(int(seed) if seed is not None else None).shuffle(order)
    tests = [(name, namespace.pop(name)) for name in order if name in namespace]
    for name, test in tests:
        namespace[name] = test


def benchmark(name, body, budget=0.2, limit=100000):
    """Measured, never asserted: the mean and fastest time of body."""
    times = []
    started = time.perf_counter()
    while len(times) < limit and (time.perf_counter() - started < budget or len(times) < 3):
        before = time.perf_counter()
        body()
        times.append(time.perf_counter() - before)
    mean = sum(times) / len(times)
    entry = {"benchmark": name, "iterations": len(times), "mean_ns": int(mean * 1e9), "min_ns": int(min(times) * 1e9)}
    print(f"benchmark {name}: {len(times)} iteration(s), mean {mean * 1e6:.2f} us, fastest {min(times) * 1e6:.2f} us")
    _record("benchmark " + name, entry)
