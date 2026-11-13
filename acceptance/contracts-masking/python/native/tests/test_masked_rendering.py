"""A masked record's native renderings: what is masked, and what is not."""

import dataclasses
import logging

import lawspec_data as data
import lawspec_runtime as ls
import pytest
from lawspec_definitions.example import masking as definitions

CARD = data.Card("Ann Lee", "4111111111111111", "ann@example.org", 900, 1234)
MASKED = "Card{holder=***, number=***1111, contact=a***@example.org, limit=900, pin=***}"


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
        logging.getLogger("example.masked").info(
            "placed %s and %r", CARD, [CARD]
        )
    nothing_raw(caplog.text)
    assert MASKED in caplog.text


def test_the_unmasked_rendering_is_explicit():
    assert "4111111111111111" in CARD.unmasked_repr()


def test_fields_and_asdict_are_the_wire_form_and_are_not_masked():
    assert dataclasses.asdict(CARD)["number"] == "4111111111111111"


# Keyed BLAKE3-256 under the key below, from
# test/fixtures/blake3-keyed-text.json: the digests LawSpec's Haskell port
# computes. They tie this runtime to it.
LETTERS = [
    (0, "92b2b75604ed3c761f9d6f62392c8a9227ad0ea3f09573e783f1498a4ed60d26"),
    (1, "36a6d4db841fe91831fe6d0fe35623a3a47269dd94d84ac68cb8ba7cd26ba3a2"),
    (64, "81873b794210dfd69cc8d2124ae9606f741743c60ef56d1eacd7a2a98d4d5807"),
    (65, "a3e4916d04ae832e039226fcae19845b35de0289e59dceb7d51a6994d806d3e2"),
    (1024, "1e585da86aa6772d1792955fed46e2fe7362f5564b64612c88602b964538986a"),
    (1025, "09fbf44f6e68576dd4082a72cc176a2865513031c6200df32eebdf77894b2b8f"),
    (2048, "e3deeb5a2004cc135d0c60d694a06d746a6ffbcc5009e31368d3e2af360f985a"),
    (2049, "b4467e073bfa567e4a337b8b8a04da641184522ae5bb753584244a1f37696c4c"),
    (3073, "5795c366f3dd3d823ee2b8bf21724bdd1a0fe378a8616dba2b011c46715125f2"),
    (5121, "269647e2dd34dd8055e7f39620b006c91d516b658203d5404583575c1e0c545e"),
    (8193, "67af3328f4c7f02f0d20e2921dd61513170f6151748e2989b3dd4f775c099236"),
]
MIXED = [
    (1, "7bdcc4c951f17b858dd3098096a6bfc4618d2e712012ea8deda5db2b40207365"),
    (300, "a4d2df6b99760f8ac8e166f46ab4427e8e987aeef49768283c5061cfceb9372d"),
]


def test_a_hashed_field_needs_a_key_and_shows_the_keyed_digest(monkeypatch):
    session = data.Session("ann", "tok-12345678")
    monkeypatch.setattr(ls, "_MASK_HASH_KEY", None)
    with pytest.raises(RuntimeError, match="no key is set"):
        repr(session)
    with pytest.raises(TypeError, match="32 bytes"):
        ls.set_mask_hash_key(b"short")
    ls.set_mask_hash_key(b"whats the Elvish word for friend")
    for count, digest in LETTERS:
        text = ("abcdefghijklmnopqrstuvwxyz" * 400)[:count]
        assert ls.mask_hash(text) == "hash:" + digest
    for count, digest in MIXED:
        assert (
            ls.mask_hash("a\u00e9\u20ac\U0001f600" * count) == "hash:" + digest
        )
    shown = repr(session)
    assert (
        shown == "Session{user=ann, token=" + ls.mask_hash("tok-12345678") + "}"
    )
    assert "tok-12345678" not in shown
    assert str(session) == shown
    assert (
        definitions.maskedSession({}, session) == "Session{user=ann, token=***}"
    )
    assert "tok-12345678" in session.unmasked_repr()
