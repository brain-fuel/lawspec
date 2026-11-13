"""A digest needs no key: a specification's digest, the runtime's and a
record's native rendering are one text."""

import lawspec_data as data
import lawspec_runtime as ls
from lawspec_definitions.example import digest as definitions

TEXTS = [
    "",
    "abc",
    "GB82WEST12345698765432",
    "a\u00e9\u20ac\U0001f600" * 300,
    "x" * 5121,
]
# BLAKE3 of no bytes and of "abc", as b3sum prints them; the first is the
# first of the official test vectors (test/fixtures/blake3-official).
PUBLISHED = [
    ("", "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"),
    ("abc", "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"),
]
IBAN = "GB82WEST12345698765432"


def test_mask_digest_in_a_specification_is_the_runtime_mask_digest():
    for text in TEXTS:
        shown = definitions.fingerprint({}, text)
        assert shown == ls.mask_digest(text)
        assert shown == ls.mask_digest_blake3(text)
        scoped = definitions.fingerprintIn({}, "orders", text)
        assert scoped == ls.mask_digest_in("orders", text)
        assert scoped == ls.mask_digest_blake3_in("orders", text)
        assert scoped != shown
    for text, digest in PUBLISHED:
        assert definitions.fingerprint({}, text) == "digest:" + digest


def test_the_default_digest_is_the_blake3_one():
    assert ls.mask_digest is ls.mask_digest_blake3
    assert ls.mask_digest_in is ls.mask_digest_blake3_in


def test_a_record_shows_its_digests_natively_with_no_key_set():
    account = data.Account("ann", IBAN, IBAN)
    shown = definitions.maskedAccount({}, account)
    assert shown == repr(account)
    assert shown == (
        "Account{owner=ann"
        ", iban=digest:bef19ccbcf87f759cb18235af8a4d031a4cd89369514a9300e348803fe129d02"
        ", reference=digest:c88e885494a2d3f82a49e3efbda8ab5dad1560ac499caa380ba9db31abb5a727}"
    )
    assert IBAN not in f"{account}"
    assert IBAN in account.unmasked_repr()


def test_a_field_has_its_own_context():
    shown = repr(data.Account("ann", IBAN, IBAN))
    assert ls.mask_digest_in("example.digest.Account.iban", IBAN) in shown
    assert ls.mask_digest_in("example.digest.Account.reference", IBAN) in shown
    assert ls.mask_digest(IBAN) not in shown


def test_a_half_of_a_surrogate_pair_is_hashed_as_the_replacement_character():
    for lone, replaced in [
        ("\ud800", "\ufffd"),
        ("\udc00", "\ufffd"),
        ("a\ud83d", "a\ufffd"),
    ]:
        assert ls.mask_digest(lone) == ls.mask_digest(replaced)
        assert ls.mask_digest_in("orders", lone) == ls.mask_digest_in(
            "orders", replaced
        )


def test_a_failure_shows_a_digest_field_as_its_digest():
    data.make_schema()
    tag = "example.digest::type::Account::Account"
    printed = repr(ls.DataValue(tag, ("ann", IBAN, IBAN)))
    assert IBAN not in printed
    assert ls.mask_digest_in("example.digest.Account.iban", IBAN) in printed
