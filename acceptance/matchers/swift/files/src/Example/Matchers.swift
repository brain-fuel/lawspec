// User-owned LawSpec adapters for the matchers example.
// ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.Matchers {
    static func sortItems(_ items: PersistentList<Int32>) -> PersistentList<Int32> { PersistentList(items.sorted()) }

    static func uniqueTags(_ tags: PersistentList<String>) -> PersistentList<String> {
        var seen = [String]()
        for tag in tags where !seen.contains(where: { String.portableEqual($0, tag) }) { seen.append(tag) }
        return PersistentList(seen)
    }

    static func average(_ a: Int32, _ b: Int32) -> Double { (Double(a) + Double(b)) / 2.0 }

    /// The lowercase runs of letters and digits, joined by dashes.
    static func slug(_ text: String) -> String {
        var words = [String]()
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: "-")
    }

    static func ship(_ id: Int32) -> Order { .shipped(value: Recordaaeb2c3925832586ac7d5e3c9a9cd234d3a26f7d9d0e264664a4ae58c6f71911(carrier: "post", id: id)) }
}
