"""Observe real emitted strategy hints without replacing their generation."""
import importlib
import inspect

from hypothesis import seed
import pytest


def observe_hints(generated, monkeypatch, observed):
    original = generated._data_strategy

    def checked(*arguments, **keywords):
        reference, witnesses = arguments[1], arguments[6]
        frame = inspect.currentframe().f_back
        if reference.name == "Int64":
            earlier = frame.f_locals.get("earlier")
            if earlier is None:
                assert all(1001 <= value <= 1002 for value in witnesses)
            else:
                assert all(1002 <= value <= 1003 and value > earlier
                           for value in witnesses)
            observed.append((reference.name, len(witnesses)))
        elif reference.name == "Int8":
            # 127 is the real type boundary that this restricted domain keeps.
            assert witnesses == [127]
            observed.append((reference.name, len(witnesses)))
        return original(*arguments, **keywords)

    monkeypatch.setattr(generated, "_data_strategy", checked)


@pytest.mark.parametrize("replay_seed", [25223908019183950680600183627505699360, 0, 1, 2])
def test_contextual_hints_respect_the_current_restrictions(monkeypatch, replay_seed):
    generated = importlib.import_module("test_checkedPrimitiveInputs_lawspec")
    observed = []
    observe_hints(generated, monkeypatch, observed)
    seed(replay_seed)(generated.test_dependentranges__property)()
    seed(replay_seed)(generated.test_retainedupperboundary__property)()
    assert any(name == "Int64" for name, _ in observed)
    assert any(name == "Int8" and count == 1 for name, count in observed)


class DeliberateCounterexample(Exception):
    pass


def test_dependent_hints_are_rechecked_while_the_framework_shrinks(monkeypatch):
    generated = importlib.import_module("test_checkedPrimitiveInputs_lawspec")
    observed = []
    prefixes = set()
    observe_hints(generated, monkeypatch, observed)
    original_assert = generated._lawspec_assert

    def fail_on_upper_prefix(*arguments):
        original_assert(*arguments)
        earlier = inspect.currentframe().f_back.f_locals["earlier"]
        prefixes.add(earlier)
        if earlier == 1002:
            raise DeliberateCounterexample("exercise native dependent shrinking")

    monkeypatch.setattr(generated, "_lawspec_assert", fail_on_upper_prefix)
    with pytest.raises(DeliberateCounterexample):
        seed(0)(generated.test_dependentranges__property)()
    assert prefixes == {1001, 1002}
    assert observed
