"""A masked record's native renderings: what is masked, and what is not."""

import dataclasses
import logging

import lawspec_data as data
from lawspec_definitions.example import masking as definitions

CARD = data.Card("Ann Lee", "4111111111111111", "ann@example.org", 900, 1234)
MASKED = (
    "Card{holder=***, number=***1111, contact=a***@example.org, limit=900, pin=***}"
)


def nothing_raw(text):
    for raw in ("Ann Lee", "4111111111111111", "ann@example.org", "1234"):
        assert raw not in text, f"shows {raw}: {text}"


def test_repr_and_str_are_the_checked_masked_rendering():
    assert repr(CARD) == MASKED
    assert str(CARD) == MASKED
    assert definitions.maskedCard({}, CARD) == MASKED
    nothing_raw(f"card: {CARD}")
    nothing_raw(f"card: {CARD!r}")
    nothing_raw(repr([CARD, {"card": CARD}]))


def test_a_logger_prints_nothing_raw(caplog):
    with caplog.at_level(logging.INFO):
        logging.getLogger("example.masked").info("placed %s and %r", CARD, [CARD])
    nothing_raw(caplog.text)
    assert MASKED in caplog.text


def test_the_unmasked_rendering_is_explicit():
    assert "4111111111111111" in CARD.unmasked_repr()


def test_fields_and_asdict_are_the_wire_form_and_are_not_masked():
    assert dataclasses.asdict(CARD)["number"] == "4111111111111111"
