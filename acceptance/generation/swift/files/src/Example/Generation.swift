// User-owned LawSpec adapter: the portable generator under test.
// ref:DEC-portable-seeded-generation ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.Generation {
    static func generated(_ text: String, _ seed: UInt64, _ size: Int32, _ count: Int32) -> PersistentList<String> {
        PersistentList(try! Descriptors.generated(text, BigInt(seed), Int(size), Int(count)))
    }

    static func shrunk(_ text: String, _ seed: UInt64, _ size: Int32) -> PersistentList<String> {
        PersistentList(try! Descriptors.shrunk(text, BigInt(seed), Int(size)))
    }
}
