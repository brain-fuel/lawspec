// User-owned LawSpec adapter: native handlers for the shop's abilities, and
// a native adapter that fails with a typed throw.
// ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.Shop {
    /// (Int32 -> Int32)
    static func refund(_ gateway: any LawSpec.Abilities.ExampleAbilities.Gateway, _ value0: Int32) throws(PaymentError) -> Int32 {
        if value0 > 100000 { throw .tooLarge }
        return gateway.capture(value0).cents
    }

    /// The native handler of Log: note.
    static func logHandler() -> any LawSpec.Abilities.ExampleShop.Log { NativeLog() }

    final class NativeLog: LawSpec.Abilities.ExampleShop.Log {
        var lines = [String]()
        func note(_ value0: String) { lines.append(value0) }
    }

    /// The native handler of Store Int32: load, save.
    static func storeInt32Handler() -> any LawSpec.Abilities.ExampleShop.StoreInt32 { NativeStoreInt32() }

    final class NativeStoreInt32: LawSpec.Abilities.ExampleShop.StoreInt32 {
        var stored: Int32 = 0
        func load() -> Int32 { stored }
        func save(_ value0: Int32) { stored = value0 }
    }

    /// The native handler of Store Text: load, save.
    static func storeTextHandler() -> any LawSpec.Abilities.ExampleShop.StoreText { NativeStoreText() }

    final class NativeStoreText: LawSpec.Abilities.ExampleShop.StoreText {
        var stored = ""
        func load() -> String { stored }
        func save(_ value0: String) { stored = value0 }
    }

    /// The native handler of Meter: reading.
    static func meterHandler() -> any LawSpec.Abilities.ExampleShop.Meter { NativeMeter() }

    struct NativeMeter: LawSpec.Abilities.ExampleShop.Meter {
        func reading() -> Int32 { 3 }
    }
}
