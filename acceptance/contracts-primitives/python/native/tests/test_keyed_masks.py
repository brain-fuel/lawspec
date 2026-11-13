"""The masks a specification calls are the runtime's own, under the same key."""

import lawspec_data as data
import lawspec_runtime as ls
import pytest
from lawspec_definitions.example import keyed as definitions

KEY = b"whats the Elvish word for friend"
TEXTS = [
    "",
    "abc",
    "tok-12345678",
    "a\u00e9\u20ac\U0001f600" * 300,
    "x" * 5121,
]
# test/fixtures/blake3-keyed-text.json: the same rows in every runtime.
RECORDED = [
    ("abc", "157f8b4b104070014ab0b3b7aff364f794e010e92b1c976318e892f380b53406"),
    (
        "\ufffd",
        "b08a37ba71c80d97211ca1ecbc0e82e0254499a3004691544ffdb4425702ec8e",
    ),
]


def test_mask_hash_in_a_specification_is_the_runtime_mask_hash_under_the_key():
    ls.set_mask_key(KEY)
    for text in TEXTS:
        shown = definitions.fingerprint({}, KEY, text)
        assert shown == ls.mask_hash(text)
        assert shown == ls.mask_hash_blake3(text)
        assert shown == ls.mask_hash_with(KEY, text)
        assert shown == ls.mask_hash_blake3_with(KEY, text)
    for text, digest in RECORDED:
        assert definitions.fingerprint({}, KEY, text) == "hash:" + digest


def test_the_default_hash_is_the_blake3_one():
    assert ls.mask_hash is ls.mask_hash_blake3
    assert ls.mask_hash_with is ls.mask_hash_blake3_with


def test_a_record_rendered_with_the_key_is_its_native_rendering():
    ls.set_mask_key(KEY)
    session = data.Session("ann", "tok-12345678", "c")
    shown = definitions.maskedSessionWith({}, KEY, session)
    assert shown == repr(session)
    assert shown.startswith("Session{user=ann, token=hash:")
    assert "tok-12345678" not in shown
    assert (
        definitions.maskedSession({}, session)
        == "Session{user=ann, token=***, device=***}"
    )


def test_a_half_of_a_surrogate_pair_is_hashed_as_the_replacement_character():
    for lone, replaced in [
        ("\ud800", "\ufffd"),
        ("\udc00", "\ufffd"),
        ("a\ud83d", "a\ufffd"),
    ]:
        assert ls.mask_hash_with(KEY, lone) == ls.mask_hash_with(KEY, replaced)
    assert ls.mask_hash_with(KEY, "\ud800") == "hash:" + RECORDED[1][1]


def test_a_key_that_is_not_32_bytes_is_refused():
    with pytest.raises(TypeError, match="32 bytes"):
        ls.mask_hash_with(bytes(31), "abc")
    with pytest.raises(Exception, match="precondition"):
        definitions.fingerprint({}, bytes(31), "abc")


def test_mask_star_shows_nothing():
    assert ls.mask_star("tok-12345678") == "***"
    assert ls.mask_star(1234) == "***"
