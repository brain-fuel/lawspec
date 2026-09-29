"""Check emitted codec hooks using only the standard library."""

from dataclasses import dataclass
import unittest

import codec_domain as domain
import codec_hooks as hooks
import lawspec_data as data
import lawspec_native as bridge
import lawspec_runtime as ls
from lawspec_schema import Named


PARCEL = "native.codecs::type::Parcel"
TAG = PARCEL + "::Parcel"


class CodecBindingsTests(unittest.TestCase):
    def test_generic_symbol_identity_and_nested_native_types(self):
        symbol = ls.Symbol("same")
        child = Named(PARCEL, [Named("Symbol")])
        reference = Named(PARCEL, [child])
        value = ls.DataValue(TAG, [ls.DataValue(TAG, [symbol])])
        native = bridge._native.to_native(reference, value)
        self.assertIsInstance(native.unpack(), domain.Parcel)
        self.assertIs(native.unpack().unpack(), symbol)
        result = bridge._native.from_native(reference, native)
        self.assertIs(result.fields[0].fields[0], symbol)
        self.assertTrue(bridge._canonical.equal(reference, value, result))

    def test_raw_payloads_and_both_machine_profiles(self):
        for bits in (32, 64):
            for name, payload in (("Bytes", bytes([0, 255])),
                                  ("Utf16Text", ls.Raw("Utf16Text",
                                                       [0xD800, 0xFFFF])),
                                  ("CodePointText", ls.Raw(
                                      "CodePointText", [0xD800, 0x10FFFF]))):
                reference = Named(PARCEL, [Named(name)])
                value = ls.DataValue(TAG, [payload])
                native = bridge._native.to_native(reference, value, bits)
                result = bridge._native.from_native(reference, native, bits)
                self.assertTrue(bridge._canonical.equal(
                    reference, value, result, bits))

    def test_child_converter_rejects_out_of_range_payload(self):
        reference = Named(PARCEL, [Named("Int8")])
        with self.assertRaisesRegex(ValueError, "Parcel fromNative"):
            bridge._native.from_native(reference, domain.Parcel(128))

    def test_wrong_native_type_and_result_are_contextual(self):
        reference = Named(PARCEL, [Named("Int8")])
        with self.assertRaisesRegex(ValueError, "bound native type"):
            bridge._native.from_native(reference, data.ParcelParcel(1))
        native = bridge._canonical.with_native_bindings({}, {
            PARCEL: (domain.Parcel, lambda value, child: object(),
                     lambda value, child: data.ParcelParcel(1)),
        })
        with self.assertRaisesRegex(ValueError, "wrong native type"):
            native.to_native(reference, ls.DataValue(TAG, [1]))

    def test_hooks_compose_with_direct_mappings(self):
        @dataclass
        class MappedPositive:
            value: int

        positive = "native.codecs::type::Positive"
        native = bridge._canonical.with_native_bindings(
            {positive + "::Positive": (MappedPositive, ["value"])},
            {PARCEL: (domain.Parcel, hooks.to_parcel, hooks.from_parcel)})
        reference = Named(PARCEL, [Named(positive)])
        value = ls.DataValue(TAG, [ls.DataValue(positive + "::Positive", [7])])
        app = native.to_native(reference, value)
        self.assertIsInstance(app.unpack(), MappedPositive)
        self.assertEqual(app.unpack().value, 7)
        self.assertTrue(bridge._canonical.equal(
            reference, value, native.from_native(reference, app)))

    def test_invalid_hook_registrations(self):
        for name, hook in (("missing", (domain.Parcel, lambda x: x,
                                        lambda x: x)),
                           (PARCEL, (domain.Parcel, None, None))):
            with self.assertRaises((ValueError, TypeError)):
                bridge._canonical.with_native_bindings({}, {name: hook})
        with self.assertRaisesRegex(ValueError, "conflicts"):
            bridge._canonical.with_native_bindings(
                {TAG: (domain.Parcel, ["item"])},
                {PARCEL: (domain.Parcel, lambda x: x, lambda x: x)})


if __name__ == "__main__":
    unittest.main()
