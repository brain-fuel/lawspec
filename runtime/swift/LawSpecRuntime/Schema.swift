// The checked shapes of a program's data: constructors, field types, GADT
// equations, existential witnesses, index guards and field contracts, all
// checked by one walk. The schema also carries the handlers in scope.
// ref:DEC-typed-core-boundary ref:DEC-gadts-and-index-arithmetic

/// A constructor field's predicate: the schema, the type's arguments and the
/// fields to whether they hold.
public typealias FieldPredicate = @Sendable (Schema, [TypeRef], [Value]) throws -> Bool

/// A constructor field's generation hints, from the fields drawn before it.
public typealias FieldGenerator = @Sendable (Schema, [TypeRef], [Value]) throws -> Schema.FieldHints

/// A program's data definitions, as the runtime checks them, and the handlers
/// in scope. A schema is a value: installing handlers makes another.
public struct Schema: Sendable {
  /// Bounds and hints that steer the generation of one constructor field from
  /// the fields drawn before it. ref:DEC-shrink-within-domain
  public struct FieldHints: Sendable {
    public let bounds: [(String, Value)]
    public let lengths: [(String, Value)]
    public let hints: [Value]
  }

  /// A data constructor; arguments and witness values are filled in when it
  /// is instantiated at a type.
  public struct Constructor: Sendable {
    public let tag: String
    public var fields: [(String, TypeRef)]
    public var predicates: [FieldPredicate] = []
    /// By field position, from 1.
    public var generators: [Int: FieldGenerator] = [:]
    public var indices: [String] = []
    public var refinements: [(Int, TypeRef)] = []
    public var existentials = 0
    public var witnesses: [Int] = []
    public var arguments: [TypeRef] = []
    public var witnessValues: [Value] = []
  }

  public struct DataDefinition: Sendable {
    public let name: String
    public let parameters: Int
    public let constructors: [Constructor]
    public let handle: Bool
  }

  /// The program's data: shared by every schema made from it.
  public final class Program: Sendable {
    public let definitions: [String: DataDefinition]
    public let arities: [String: Int]
    public let bits: Int
    init(definitions: [String: DataDefinition], arities: [String: Int], bits: Int) {
      self.definitions = definitions
      self.arities = arities
      self.bits = bits
    }
  }

  public let program: Program
  /// The handlers in scope, by ability key (Effects).
  public var handlers: [String: Effects.Handler] = [:]
  /// The innermost handler scope, which owns handler state.
  public var scope: Effects.Scope? = nil
  /// The stateful handlers whose operations are running, innermost first.
  public var effectPath: [ObjectIdentifier] = []

  public var definitions: [String: DataDefinition] { program.definitions }
  public var bits: Int { program.bits }

  init(program: Program) { self.program = program }

  private static func fail(_ code: String, _ detail: String = "") -> LawSpecError {
    Fail.with(code, detail)
  }

  /// A constructor with only a tag and fields; the generated schema adds the rest.
  public static func constructor(_ tag: String, _ fields: [(String, TypeRef)]) -> Constructor {
    Constructor(tag: tag, fields: fields)
  }

  /// The type parameters' types, by position.
  public static func substitute(_ t: TypeRef, _ known: [Int: TypeRef]) -> TypeRef {
    switch t {
    case .parameter(let i): return known[i] ?? t
    case .named(let name, let args): return .named(name, args.map { substitute($0, known) })
    }
  }

  private static func checkScope(_ t: TypeRef, _ scope: Int, _ schema: Schema) throws {
    switch t {
    case .parameter(let i):
      if i < 0 || i >= scope { throw fail("UnboundSchemaParameter", "\(i)") }
    case .named(let name, let args):
      guard let arity = schema.program.arities[name], arity == args.count else {
        throw fail("UnknownTypeOrArity", name)
      }
      for a in args { try checkScope(a, scope, schema) }
    }
  }

  /// Check that a closed type is known, with the right number of arguments.
  public static func checkType(_ t: TypeRef, _ schema: Schema) throws {
    try checkScope(t, 0, schema)
  }

  private static let builtins: [(String, Int)] = [
    ("List", 1), ("Maybe", 1), ("Either", 2), ("Nullable", 1), ("Optional", 1),
  ]

  /// A program's schema, from its data definitions and the scalar names.
  public static func create(_ definitions: [DataDefinition], _ primitives: [String], _ bits: Int)
    throws -> Schema
  {
    if bits != 32 && bits != 64 { throw fail("InvalidMachineBits", "\(bits)") }
    let names = definitions.map { $0.name } + primitives + builtins.map { $0.0 }
    if Set(names).count != names.count { throw fail("DuplicateType") }
    var arities = [String: Int]()
    for p in primitives { arities[p] = 0 }
    for (name, arity) in builtins { arities[name] = arity }
    for d in definitions { arities[d.name] = d.parameters }
    var table = [String: DataDefinition]()
    for d in definitions { table[d.name] = d }
    let schema = Schema(program: Program(definitions: table, arities: arities, bits: bits))
    let tags = definitions.flatMap { $0.constructors.map { $0.tag } }
    if Set(tags).count != tags.count { throw fail("DuplicateConstructor") }
    for d in definitions {
      for c in d.constructors {
        for (_, t) in c.fields { try checkScope(t, d.parameters + c.existentials, schema) }
      }
    }
    return schema
  }

  private static func unify(_ pattern: TypeRef, _ actual: TypeRef, _ known: [Int: TypeRef]?)
    -> [Int: TypeRef]?
  {
    guard var k = known else { return nil }
    switch pattern {
    case .parameter(let i):
      if let t = k[i] { return t == actual ? k : nil }
      k[i] = actual
      return k
    case .named(let name, let ps):
      guard case .named(let n, let xs) = actual, n == name, ps.count == xs.count else { return nil }
      return zip(ps, xs).reduce(k as [Int: TypeRef]?) { unify($1.0, $1.1, $0) }
    }
  }

  private static func instantiate(_ c: Constructor, _ args: [TypeRef]) -> Constructor? {
    var known = [Int: TypeRef]()
    for (i, a) in args.enumerated() { known[i] = a }
    var bound: [Int: TypeRef]? = known
    for (i, pattern) in c.refinements where i < args.count {
      bound = unify(pattern, args[i], bound)
    }
    guard let b = bound else { return nil }
    var made = c
    made.arguments = args
    made.fields = c.fields.map { ($0.0, substitute($0.1, b)) }
    return made
  }

  private static func builtinConstructors(_ name: String, _ args: [TypeRef]) -> [Constructor]? {
    switch (name, args.count) {
    case ("Maybe", 1):
      return [
        constructor("Maybe::Absent", []), constructor("Maybe::Present", [("value", args[0])]),
      ]
    case ("Either", 2):
      return [
        constructor("Either::Left", [("value", args[0])]),
        constructor("Either::Right", [("value", args[1])]),
      ]
    default: return nil
    }
  }

  /// The constructors of a data type at its arguments, or nil for a scalar or
  /// a list. A GADT constructor whose equations the arguments refute is absent.
  public static func constructors(_ t: TypeRef, _ schema: Schema) throws -> [Constructor]? {
    try checkType(t, schema)
    guard case .named(let name, let args) = t else { return nil }
    guard let d = schema.program.definitions[name] else { return builtinConstructors(name, args) }
    return d.constructors.compactMap { instantiate($0, args) }
  }

  /// Each instance of a constructor's free existentials over Core's finite
  /// witness pool (Bool and Int32).
  public static func witnessInstances(_ c: Constructor) -> [Constructor] {
    let pool: [TypeRef] = [.named("Bool", []), .named("Int32", [])]
    var assignments: [[Int: TypeRef]] = [[:]]
    for i in c.witnesses {
      assignments = assignments.flatMap { known in pool.map { t in known.merging([i: t]) { $1 } } }
    }
    let kept = c.fields.count - c.witnesses.count
    return assignments.map { known in
      var made = c
      made.fields = c.fields.prefix(kept).map { ($0.0, substitute($0.1, known)) }
      made.witnessValues = c.witnesses.map { .text(Scalar.typeKey(known[$0]!)) }
      return made
    }
  }

  private static func findConstructor(_ tag: String, _ cs: [Constructor]) throws -> Constructor {
    let found = cs.filter { $0.tag == tag }
    guard found.count == 1 else { throw fail("ForeignConstructor", tag) }
    return found[0]
  }

  private static func witnessed(_ c: Constructor, _ values: [Value], _ schema: Schema) throws -> [(
    String, TypeRef
  )] {
    let texts = values.suffix(c.witnesses.count)
    var known = [Int: TypeRef]()
    for (i, v) in zip(c.witnesses, texts) {
      guard case .text(let key) = v else { throw fail("InvalidWitness") }
      let t = try Scalar.typeOf(key)
      try checkType(t, schema)
      known[i] = t
    }
    return c.fields.map { ($0.0, substitute($0.1, known)) }
  }

  // MARK: Index terms

  private static func tokens(_ text: String) -> [String] {
    text.split(separator: " ").map(String.init)
  }

  private static func isGuard(_ tokens: [String]) -> Bool {
    tokens.first == "==" || tokens.first == ">="
  }

  private static func indexBinary(_ op: String, _ a: BigInt?, _ b: BigInt?) -> BigInt? {
    guard let a, let b else { return nil }
    switch op {
    case "+": return a + b
    case "-" where a >= b: return a - b
    case "*": return a * b
    case "div" where b.signum > 0: return a / b
    case "mod" where b.signum > 0: return a % b
    case "^" where b.signum >= 0 && b <= 64: return a.power(b.exactly(Int.self)!)
    default: return nil
    }
  }

  private static func evalIndex(
    _ terms: ArraySlice<String>, _ c: Constructor, _ values: [Value], _ schema: Schema
  ) throws -> (BigInt?, ArraySlice<String>) {
    guard let term = terms.first else { throw fail("InvalidIndexTerm") }
    let rest = terms.dropFirst()
    if term.hasPrefix("c") {
      guard let n = BigInt(String(term.dropFirst())) else { throw fail("InvalidIndexTerm", term) }
      return (n, rest)
    }
    if term.hasPrefix("f") || term.hasPrefix("p") {
      let parts = term.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
      guard parts.count <= 2, let positions = parts.first else {
        throw fail("InvalidIndexTerm", term)
      }
      let path = positions.split(separator: "/", omittingEmptySubsequences: false).map { Int($0) }
      guard path.allSatisfy({ $0 != nil && $0! >= 0 }), !path.isEmpty,
        !term.hasPrefix("f") || path.count == 1
      else { throw fail("InvalidIndexTerm", term) }
      let inner = parts.count == 2 ? Int(parts[1]) : 0
      guard let inner, inner >= 0 else { throw fail("InvalidIndexTerm", term) }
      return (try indexAtPath(c.fields, values, path.map { $0! }[...], inner, schema), rest)
    }
    let (a, next) = try evalIndex(rest, c, values, schema)
    let (b, after) = try evalIndex(next, c, values, schema)
    return (indexBinary(term, a, b), after)
  }

  private static func indexAtPath(
    _ types: [(String, TypeRef)], _ values: [Value], _ path: ArraySlice<Int>, _ inner: Int,
    _ schema: Schema
  ) throws -> BigInt {
    guard let position = path.first, position >= 0, position < types.count, position < values.count
    else { throw fail("InvalidIndexPath") }
    let (type, value) = (types[position].1, values[position])
    if path.count == 1 { return try index(value, type, inner, schema) }
    guard case .named(let name, _) = type, name.hasPrefix("lawspec::structural::record::"),
      case .data(let tag, let fields) = value, let constructors = try constructors(type, schema),
      constructors.count == 1, constructors[0].tag == tag
    else { throw fail("InvalidIndexPath") }
    return try indexAtPath(constructors[0].fields, fields, path.dropFirst(), inner, schema)
  }

  /// The index at a position of an indexed family's value.
  public static func index(_ value: Value, _ t: TypeRef, _ position: Int, _ schema: Schema) throws
    -> BigInt
  {
    guard case .data(let tag, let values) = value, let cs = try constructors(t, schema) else {
      throw fail("IndexedTypeRequiresData", Scalar.typeKey(t))
    }
    var c = try findConstructor(tag, cs)
    c.fields = try witnessed(c, values, schema)
    let terms = c.indices.map(tokens).filter { !isGuard($0) }
    if position < 0 || position >= terms.count { throw fail("NoIndex") }
    let (v, rest) = try evalIndex(terms[position][...], c, values, schema)
    guard let found = v, rest.isEmpty else { throw fail("UndefinedIndex", tag) }
    return found
  }

  private static func checkIndices(_ c: Constructor, _ values: [Value], _ schema: Schema) throws {
    for text in c.indices {
      let parts = tokens(text)
      guard let op = parts.first, op == "==" || op == ">=" else { continue }
      let (a, next) = try evalIndex(parts.dropFirst(), c, values, schema)
      let (b, _) = try evalIndex(next, c, values, schema)
      var holds = false
      if let a, let b { holds = op == "==" ? a == b : a >= b }
      if !holds { throw fail("RefinementViolation", "index guard " + text) }
    }
  }

  // MARK: Validation

  private static func strictOrder(_ values: [Value]) throws -> Bool {
    for (a, b) in zip(values, values.dropFirst()) where try Scalar.compareValues(a, b) != -1 {
      return false
    }
    return true
  }

  private static func checkCollection(_ name: String, _ fields: [Value]) throws {
    switch (name, fields.first) {
    case ("lawspec.collections::type::EqSet", .list(let items)?):
      if !Scalar.distinctMembers(items) {
        throw fail("RefinementViolation", "Eq-only set: duplicate equal elements")
      }
    case ("lawspec.collections::type::Set", .list(let items)?):
      if !(try strictOrder(items)) { throw fail("RefinementViolation", name) }
    case ("lawspec.collections::type::KeyVal", .list(let entries)?):
      let keys = try entries.map { entry -> Value in
        guard case .data(_, let pair) = entry, pair.count == 2 else {
          throw fail("InvalidValue", name)
        }
        return pair[0]
      }
      if !(try strictOrder(keys)) { throw fail("RefinementViolation", name) }
    default:
      break
    }
  }

  private static func checkPredicates(
    _ c: Constructor, _ args: [TypeRef], _ values: [Value], _ schema: Schema
  ) throws {
    for predicate in c.predicates where !(try predicate(schema, args, values)) {
      throw fail("RefinementViolation", c.tag)
    }
  }

  /// Check a value against a type: shape, field contracts, index guards and the
  /// canonical order of collections. Returns the value.
  public static func validate(_ value: Value, _ t: TypeRef, _ schema: Schema) throws -> Value {
    try checkType(t, schema)
    return try walk(value, t, schema, true)
  }

  private static func walk(_ value: Value, _ t: TypeRef, _ schema: Schema, _ deep: Bool) throws
    -> Value
  {
    switch (t, value) {
    case (.named("List", let args), .list(let items)) where args.count == 1:
      return .list(try items.map { try walk($0, args[0], schema, deep) })
    case (.named(let kind, let args), .presence(let k, let present))
    where args.count == 1 && (kind == "Optional" || kind == "Nullable") && k == kind:
      return .presence(kind: kind, value: try present.map { try walk($0, args[0], schema, deep) })
    case (.named(let name, _), _):
      if let d = schema.program.definitions[name], d.handle {
        if case .handle(let n, _) = value, n == name { return value }
        throw fail("InvalidHandle", name)
      }
      guard let cs = try constructors(t, schema) else {
        return try Scalar.validate(value, t, schema.bits)
      }
      return try walkData(value, t, cs, schema, deep)
    case (.parameter, _):
      throw fail("UnboundSchemaParameter")
    }
  }

  private static func walkData(
    _ value: Value, _ t: TypeRef, _ cs: [Constructor], _ schema: Schema, _ deep: Bool
  ) throws -> Value {
    guard case .data(let tag, let fields) = value else {
      throw fail("ExpectedData", Scalar.typeKey(t))
    }
    var c = try findConstructor(tag, cs)
    if fields.count != c.fields.count { throw fail("WrongFieldCount", tag) }
    let typed = try witnessed(c, fields, schema)
    let converted =
      deep ? try zip(fields, typed).map { try walk($0.0, $0.1.1, schema, deep) } : fields
    var args = [TypeRef]()
    var name = ""
    if case .named(let n, let a) = t {
      args = a
      name = n
    }
    try checkPredicates(c, args, converted, schema)
    c.fields = typed
    try checkIndices(c, converted, schema)
    try checkCollection(name, converted)
    return .data(tag, converted)
  }

  /// Build a value from checked fields: the fields are not walked again, but
  /// the constructor's contracts are checked.
  public static func construct(_ tag: String, _ fields: [Value], _ t: TypeRef, _ schema: Schema)
    throws -> Value
  {
    if tag == "List::Nil" && fields.isEmpty { return .list([]) }
    if tag == "List::Cons", fields.count == 2, case .list(let tail) = fields[1] {
      return .list([fields[0]] + tail)
    }
    try checkType(t, schema)
    guard let cs = try constructors(t, schema) else {
      throw fail("ExpectedData", Scalar.typeKey(t))
    }
    return try walkData(.data(tag, fields), t, cs, schema, false)
  }

  /// The field types of a checked data value (a recording uses them to tell Text
  /// from Bytes and Char from an integer).
  public static func fieldTypes(_ value: Value, _ t: TypeRef, _ schema: Schema) throws -> [TypeRef]
  {
    guard case .data(let tag, let values) = value, let cs = try constructors(t, schema) else {
      throw fail("ExpectedData", Scalar.typeKey(t))
    }
    return try witnessed(try findConstructor(tag, cs), values, schema).map { $0.1 }
  }

  // MARK: Payloads

  private indirect enum Recipe {
    case noPayload
    case predicate((Value) throws -> Bool)
    case container(String, [Recipe])
  }

  private static func recipe(_ t: TypeRef, _ args: [Recipe]) -> Recipe {
    switch t {
    case .parameter(let i): return i < args.count ? args[i] : .noPayload
    case .named(let name, let fields):
      let children = fields.map { recipe($0, args) }
      if children.allSatisfy({ if case .noPayload = $0 { return true } else { return false } }) {
        return .noPayload
      }
      return .container(name, children)
    }
  }

  private static func payload(_ r: Recipe, _ value: Value, _ schema: Schema) throws -> Bool {
    switch (r, value) {
    case (.noPayload, _): return true
    case (.predicate(let p), _): return try p(value)
    case (.container("List", let inner), .list(let items)) where inner.count == 1:
      return try items.allSatisfy { try payload(inner[0], $0, schema) }
    case (.container(_, let inner), .presence(_, nil)) where inner.count == 1: return true
    case (.container(_, let inner), .presence(_, let v?)) where inner.count == 1:
      return try payload(inner[0], v, schema)
    case (.container("Maybe", _), .data("Maybe::Absent", _)): return true
    case (.container("Maybe", let inner), .data("Maybe::Present", let f))
    where inner.count == 1 && f.count == 1:
      return try payload(inner[0], f[0], schema)
    case (.container("Either", let inner), .data("Either::Left", let f))
    where inner.count == 2 && f.count == 1:
      return try payload(inner[0], f[0], schema)
    case (.container("Either", let inner), .data("Either::Right", let f))
    where inner.count == 2 && f.count == 1:
      return try payload(inner[1], f[0], schema)
    case (.container(let name, let args), .data(let tag, let values)):
      guard let d = schema.program.definitions[name] else { throw fail("InvalidPayload") }
      let c = try findConstructor(tag, d.constructors)
      return try zip(c.fields, values).allSatisfy {
        try payload(recipe($0.0.1, args), $0.1, schema)
      }
    default:
      throw fail("InvalidPayload")
    }
  }

  /// Whether every payload of a container (each value at a type parameter)
  /// satisfies that parameter's predicate.
  public static func allPayloads(
    _ value: Value, _ t: TypeRef, _ predicates: [(Value) throws -> Bool], _ schema: Schema
  ) throws -> Bool {
    guard case .named(let name, let args) = t else { throw fail("UnboundSchemaParameter") }
    if args.count != predicates.count { throw fail("PayloadArityMismatch", name) }
    _ = try validate(value, t, schema)
    return try payload(.container(name, predicates.map { .predicate($0) }), value, schema)
  }

  // MARK: Builders, as the generated schema module writes a program's data

  /// A field's name and type (by key).
  public static func field(_ name: String, _ key: String) throws -> (String, TypeRef) {
    (name, try Scalar.typeOf(key))
  }

  /// A data definition.
  public static func definition(
    _ name: String, _ parameters: Int, _ constructors: [Constructor], _ handle: Bool
  ) -> DataDefinition {
    DataDefinition(name: name, parameters: parameters, constructors: constructors, handle: handle)
  }

  public static func withPredicates(_ predicates: [FieldPredicate], _ c: Constructor) -> Constructor
  {
    var made = c
    made.predicates = predicates
    return made
  }

  public static func withGenerators(_ generators: [(Int, FieldGenerator)], _ c: Constructor)
    -> Constructor
  {
    var made = c
    made.generators = Dictionary(generators, uniquingKeysWith: { $1 })
    return made
  }

  public static func withIndices(_ indices: [String], _ c: Constructor) -> Constructor {
    var made = c
    made.indices = indices
    return made
  }

  public static func withRefinements(_ refinements: [(Int, TypeRef)], _ c: Constructor)
    -> Constructor
  {
    var made = c
    made.refinements = refinements
    return made
  }

  public static func withExistentials(_ count: Int, _ c: Constructor) -> Constructor {
    var made = c
    made.existentials = count
    return made
  }

  public static func withWitnesses(_ witnesses: [Int], _ c: Constructor) -> Constructor {
    var made = c
    made.witnesses = witnesses
    return made
  }

  /// A refinement of a parameter, by position, to a type (by key).
  public static func refinement(_ index: Int, _ key: String) throws -> (Int, TypeRef) {
    (index, try Scalar.typeOf(key))
  }

  /// A constructor contract's known parameter types, by position.
  public static func known(_ types: [TypeRef]) -> [Int: TypeRef] {
    Dictionary(uniqueKeysWithValues: types.enumerated().map { ($0.offset, $0.element) })
  }

  /// A field's generation hints.
  public static func hints(
    _ bounds: [(String, Value)], _ lengths: [(String, Value)], _ values: [Value]
  ) -> FieldHints {
    FieldHints(bounds: bounds, lengths: lengths, hints: values)
  }
}
