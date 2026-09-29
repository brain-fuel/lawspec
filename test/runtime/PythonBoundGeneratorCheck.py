"""The emitted factory registry uses and shrinks application-owned prices."""

from decimal import Decimal

from hypothesis import find
from hypothesis import strategies as st

import lawspec_data as data
import lawspec_generators
import lawspec_native_generators
import lawspec_schema as schema


def test_emitted_native_money_strategy_shrinks():
    source = lawspec_native_generators.strategy(
        data.make_schema(), schema.Named("example.payments::type::Money"),
        64, 64, lambda name: st.nothing())
    before = lawspec_generators.samples
    result = find(source, lambda value: value.fields[0] > Decimal("1.6"))
    assert result.fields[0] == Decimal("1.61")
    assert result.fields[1].tag == "example.payments::type::Currency::EUR"
    assert lawspec_generators.samples > before


def test_refined_scalar_uses_emitted_factory():
    import test_native_generator_checks_lawspec as checks

    before = lawspec_generators.scalar_samples
    checks.test_law0_property()
    assert lawspec_generators.scalar_samples > before


def test_finite_unit_does_not_sample_its_factory():
    import test_native_generator_checks_lawspec as checks

    assert not hasattr(checks, "test_law1_property")
    checks.test_law1_boundary0()
