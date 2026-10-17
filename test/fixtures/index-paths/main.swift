// Build in the runtime module so the fixture uses the ordinary schema API.
let chain = TypeRef.named("Chain", [])
let inner = TypeRef.named("lawspec::structural::record::inner", [])
let outer = TypeRef.named("lawspec::structural::record::outer", [])
let wrapper = TypeRef.named("Wrapper", [])
func ctor(_ tag: String, _ fields: [(String, TypeRef)], _ indices: [String] = []) -> Schema.Constructor {
    var c = Schema.constructor(tag, fields)
    c.indices = indices
    return c
}
let definitions = [
    Schema.DataDefinition(name: "Chain", parameters: 0, constructors: [ctor("Stop", [], ["c0","c10"]), ctor("Next", [("tail",chain)], ["+ f0 c1","+ f0.1 c1"])], handle: false),
    Schema.DataDefinition(name: "lawspec::structural::record::inner", parameters: 0, constructors: [ctor("Inner", [("rest",chain)])], handle: false),
    Schema.DataDefinition(name: "lawspec::structural::record::outer", parameters: 0, constructors: [ctor("Outer", [("child",inner),("sibling",chain)], ["== p0/0.0 f1"])], handle: false),
    Schema.DataDefinition(name: "Wrapper", parameters: 0, constructors: [ctor("Wrap", [("payload",outer)], ["p0/0/0.0","p0/0/0.1","== p0/0/0.1 + p0/1.0 c10","== p0/0/0.0 p0/1.0",">= p0/0/0.0 c1"])], handle: false)
]
let stop = Value.data("Stop", [])
let one = Value.data("Next", [stop])
let two = Value.data("Next", [one])
func wrapped(_ left: Value, _ right: Value) -> Value { .data("Wrap", [.data("Outer", [.data("Inner", [left]),right])]) }
for bits in [32,64] {
    let schema = try Schema.create(definitions, [], bits)
    func product(_ left: Value, _ right: Value) -> Value { .data("Outer", [.data("Inner", [left]),right]) }
    _ = try Schema.validate(product(two,two), outer, schema)
    var invalidProduct = false
    do { _ = try Schema.validate(product(two,stop), outer, schema) }
    catch let error as LawSpecError { invalidProduct = error.code == "RefinementViolation" }
    precondition(invalidProduct, "accepted invalid intrinsic record guard without parent")
    let good = try Schema.validate(wrapped(two,two), wrapper, schema)
    let first = try Schema.index(good, wrapper, 0, schema)
    let second = try Schema.index(good, wrapper, 1, schema)
    precondition(first == 2 && second == 12)
    for bad in [wrapped(two,one),wrapped(stop,stop)] {
        var rejected = false
        do { _ = try Schema.validate(bad, wrapper, schema) }
        catch let error as LawSpecError { rejected = error.code == "RefinementViolation" }
        precondition(rejected, "accepted mismatched or underflowing indices")
    }
}
print("index path conformance: Swift, both widths")
