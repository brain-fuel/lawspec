// Generation from a program's schema: scalars within their refinement
// bounds, lists within their lengths, and data within a structural budget
// that counts every node, so recursive types terminate without a hidden cap
// and deep singletons stay reachable. Indexed families are solved backwards
// from their target index. ref:DEC-structural-size-budget
// ref:DEC-shrink-within-domain ref:DEC-indexed-families-as-evidence

import LawSpecRuntime

public enum Generators {
  /// A comparison bound on an input, or on its length.
  public enum Bound {
    case compare(String, Value)
    case length(String, Value)
  }

  /// A native generator for a data type, given generators for its arguments.
  public typealias Factory = ([Gen<Value>]) throws -> Gen<Value>

  /// What generation reads beyond the schema: native generator factories by
  /// type name (from lawspec.edn) and the attempts budget.
  public struct Context {
    public let schema: Schema
    public let symbols: SymbolContext
    public let factories: [String: Factory]
    public let attempts: Int
    public init(schema: Schema, symbols: SymbolContext, factories: [String: Factory], attempts: Int)
    {
      self.schema = schema
      self.symbols = symbols
      self.factories = factories
      self.attempts = attempts
    }
  }

  private struct MinimumKey: Hashable {
    let program: ObjectIdentifier
    let type: TypeRef
    let limit: Int
  }

  private static let minimums = Locked([MinimumKey: Int?]())

  private static func exactBound(_ value: Value) throws -> (BigInt, BigInt) {
    let (n, d) = try Scalar.exact(value)
    let (q, r) = n.quotientAndRemainder(dividingBy: d)
    let floor = q - (n.isNegative && !r.isZero ? .one : .zero)
    let ceil = floor + (r.isZero ? .zero : .one)
    return (floor, ceil)
  }

  private static func lower(_ lo: BigInt?, _ n: BigInt) -> BigInt? {
    lo.map { BigInt.max($0, n) } ?? n
  }
  private static func upper(_ hi: BigInt?, _ n: BigInt) -> BigInt? {
    hi.map { BigInt.min($0, n) } ?? n
  }

  private static func limit(_ range: (BigInt?, BigInt?), _ bound: (String, Value)) throws -> (
    BigInt?, BigInt?
  ) {
    let (lo, hi) = range
    let (floor, ceil) = try exactBound(bound.1)
    switch bound.0 {
    case ">": return (lower(lo, floor + .one), hi)
    case ">=": return (lower(lo, ceil), hi)
    case "<": return (lo, upper(hi, ceil - .one))
    case "<=": return (lo, upper(hi, floor))
    case "==": return (lower(lo, ceil), upper(hi, floor))
    default: return (lo, hi)
    }
  }

  private static func lengths(_ bounds: [Bound]) -> [(String, Value)] {
    bounds.compactMap { if case .length(let op, let v) = $0 { return (op, v) } else { return nil } }
  }

  private static func comparisons(_ bounds: [Bound]) -> [(String, Value)] {
    bounds.compactMap {
      if case .compare(let op, let v) = $0 { return (op, v) } else { return nil }
    }
  }

  private static func lengthRange(_ bounds: [Bound]) throws -> (BigInt?, BigInt?) {
    try lengths(bounds).reduce((BigInt.zero as BigInt?, nil as BigInt?)) { try limit($0, $1) }
  }

  private static func lengthAllowed(_ n: Int, _ bounds: [Bound]) throws -> Bool {
    let (lo, hi) = try lengthRange(bounds)
    let count = BigInt(n)
    return (lo.map { count >= $0 } ?? true) && (hi.map { count <= $0 } ?? true)
  }

  private static func lengthGenerator(_ bounds: [Bound], _ size: Int) throws -> Gen<Int> {
    let (lo, hi) = try lengthRange(bounds)
    if let l = lo, let h = hi, l > h { return .empty }
    let low = lo ?? .zero
    return Gens.integer(low, upper(hi, BigInt.max(low, BigInt(size)))).map {
      $0.exactly(Int.self) ?? Int.max
    }
  }

  private static func sequenceOf<A>(_ element: Gen<A>, _ bounds: [Bound]) -> Gen<[A]> {
    if lengths(bounds).isEmpty { return Gens.list(element) }
    return Gen.sized { size in try lengthGenerator(bounds, size).bind { Gens.vector($0, element) } }
  }

  private static var unicodeScalar: Gen<BigInt> {
    Gens.oneOf([
      Gens.integer(.zero, BigInt(0xD7FF)), Gens.integer(BigInt(0xE000), BigInt(0x10FFFF)),
    ])
  }

  private static func ieee(_ width: Int) -> Gen<Value> {
    Gens.integer(.zero, (BigInt.one << width) - .one).map {
      .float(width: width, bits: $0.truncated(UInt64.self))
    }
  }

  private static func scalar(_ context: Context, _ t: TypeRef, _ bounds: [Bound]) throws -> Gen<
    Value
  > {
    guard case .named(let name, let args) = t, args.isEmpty else {
      throw Fail.with("NoGenerator", Scalar.typeKey(t))
    }
    switch name {
    case "Bool": return Gens.oneOf([.constant(.bool(false)), .constant(.bool(true))])
    case "Unit": return .constant(.unit)
    case "Null": return .constant(.null)
    case "Undefined": return .constant(.undefined)
    case "Rational":
      return Gens.integer(nil, nil).bind { n in
        Gens.integer(.one, nil).map { d in try Scalar.ratio(n, d) }
      }
    case "Decimal":
      return Gens.integer(nil, nil).bind { c in
        Gen.sized { size in Gens.range(-size, size).map { .decimal(c, $0) } }
      }
    case "Float32": return ieee(32)
    case "Float64": return ieee(64)
    case "Complex64", "Complex128":
      let w = name == "Complex64" ? 32 : 64
      return ieee(w).bind { r in ieee(w).map { i in .complex(width: w, real: r, imaginary: i) } }
    case "Char": return unicodeScalar.map { .int($0) }
    case "CodePoint": return Gens.integer(.zero, BigInt(0x10FFFF)).map { .int($0) }
    case "CodeUnit16": return Gens.integer(.zero, BigInt(0xFFFF)).map { .int($0) }
    case "Text":
      return sequenceOf(unicodeScalar, bounds).map {
        .text(try Scalar.textOfPoints($0.map { $0.exactly(Int.self)! }))
      }
    case "Bytes":
      return sequenceOf(Gens.integer(.zero, BigInt(255)), bounds).map {
        .bytes($0.map { $0.truncated(UInt8.self) })
      }
    case "CodePointText", "Utf16Text":
      let top = name == "CodePointText" ? 0x10FFFF : 0xFFFF
      return sequenceOf(Gens.integer(.zero, BigInt(top)), bounds).map {
        .raw(kind: name, units: $0.map { $0.exactly(Int.self)! })
      }
    case "Symbol":
      return Gens.integer(.zero, nil).map { n in
        let key = n.description
        return .symbol(context.symbols.identity("generated:" + key), key)
      }
    default:
      if Scalar.isIntegerType(name) {
        let (lo, hi) = try comparisons(bounds).reduce(try Scalar.bounds(name, context.schema.bits))
        { try limit($0, $1) }
        if let l = lo, let h = hi, l > h { return .empty }
        return Gens.integer(lo, hi).map { .int($0) }
      }
      throw Fail.with("NoGenerator", Scalar.typeKey(t))
    }
  }

  /// Whether a value is a member of its type, contracts included.
  public static func accepted(_ value: Value, _ t: TypeRef, _ schema: Schema) throws -> Bool {
    do {
      _ = try Schema.validate(value, t, schema)
      return true
    } catch let failure as LawSpecError where failure.code == "RefinementViolation" {
      return false
    }
  }

  private static func valueNodes(_ value: Value) -> Int {
    switch value {
    case .data(_, let fields): return 1 + fields.reduce(0) { $0 + valueNodes($1) }
    case .presence(_, let v?): return 1 + valueNodes(v)
    case .list(let items): return 1 + items.reduce(0) { $0 + 1 + valueNodes($1) }
    default: return 1
    }
  }

  /// Sets and maps are canonical: sorted and without duplicate keys, also
  /// after every shrink.
  private static func canonical(_ t: TypeRef, _ value: Value) throws -> Value {
    func distinctSorted(_ items: [Value], _ key: (Value) -> Value) throws -> [Value] {
      let sorted = try items.sorted { try Scalar.compareValues(key($0), key($1)) < 0 }
      var result = [Value]()
      for item in sorted {
        if let last = result.last, try Scalar.compareValues(key(last), key(item)) == 0 { continue }
        result.append(item)
      }
      return result
    }
    switch (t, value) {
    case (.named("lawspec.collections::type::EqSet", _), .data(let tag, let f)):
      if f.count == 1, case .list(let items) = f[0] {
        var distinct = [Value]()
        for item in items {
          if !distinct.contains(where: { Scalar.equal(item, $0) }) { distinct.append(item) }
        }
        return .data(tag, [.list(distinct)])
      }
    case (.named("lawspec.collections::type::Set", _), .data(let tag, let f)):
      if f.count == 1, case .list(let items) = f[0] {
        return .data(tag, [.list(try distinctSorted(items) { $0 })])
      }
    case (.named("lawspec.collections::type::KeyVal", _), .data(let tag, let f)):
      if f.count == 1, case .list(let entries) = f[0] {
        return .data(
          tag,
          [
            .list(
              try distinctSorted(entries) { entry in
                if case .data(_, let pair) = entry, pair.count == 2 { return pair[0] }
                return entry
              })
          ])
      }
    default:
      break
    }
    return value
  }

  private static func factory(_ context: Context, _ t: TypeRef) -> Factory? {
    guard case .named(let name, _) = t else { return nil }
    return context.factories[name]
  }

  private static func inhabited(_ context: Context, _ t: TypeRef, _ budget: Int) throws -> Bool {
    if budget < 1 { return false }
    if case .named(let name, _) = t, ["List", "Optional", "Nullable"].contains(name) {
      return true
    }
    if factory(context, t) != nil { return true }
    guard let cs = try Schema.constructors(t, context.schema) else { return true }
    return try cs.flatMap(Schema.witnessInstances).contains { c in
      try allocation(context, c.fields, budget - 1 - c.witnessValues.count) != nil
    }
  }

  /// The least structural cost of a type, if it is at most the limit.
  public static func minimum(_ context: Context, _ t: TypeRef, _ limit: Int) throws -> Int? {
    if limit < 1 { return nil }
    let key = MinimumKey(program: ObjectIdentifier(context.schema.program), type: t, limit: limit)
    if let known = minimums.with({ $0[key] }) { return known }
    var cost: Int? = nil
    for c in 1...limit where try inhabited(context, t, c) {
      cost = c
      break
    }
    minimums.with { $0[key] = cost }
    return cost
  }

  private static func costs(
    _ context: Context, _ fields: ArraySlice<(String, TypeRef)>, _ budget: Int
  ) throws -> [Int]? {
    guard let (_, t) = fields.first else { return budget >= 0 ? [] : nil }
    if budget < 1 { return nil }
    guard let cost = try minimum(context, t, budget),
      let more = try costs(context, fields.dropFirst(), budget - cost)
    else { return nil }
    return [cost] + more
  }

  /// Each field's budget: its minimum, plus an even share of what is left.
  public static func allocation(_ context: Context, _ fields: [(String, TypeRef)], _ budget: Int)
    throws -> [Int]?
  {
    guard let least = try costs(context, fields[...], budget) else { return nil }
    if least.isEmpty { return [] }
    let extra = budget - least.reduce(0, +)
    let count = least.count
    return least.enumerated().map { i, cost in cost + extra / count + (i < extra % count ? 1 : 0) }
  }

  private static func build(_ context: Context, _ t: TypeRef, _ budget: Int, _ bounds: [Bound])
    throws -> Gen<Value>
  {
    if let f = factory(context, t) { return try custom(context, t, budget, bounds, f) }
    return try buildNative(context, t, budget, bounds)
  }

  private static func custom(
    _ context: Context, _ t: TypeRef, _ budget: Int, _ bounds: [Bound], _ f: Factory
  ) throws -> Gen<Value> {
    var args = [TypeRef]()
    if case .named(_, let a) = t { args = a }
    let children = try args.map { child -> Gen<Value> in
      let available = Swift.max(1, budget - 1)
      return try minimum(context, child, available) == nil
        ? .empty : try build(context, child, available, [])
    }
    let checked = try f(children).map { try Schema.validate($0, t, context.schema) }
    if bounds.isEmpty { return checked }
    let key = Scalar.typeKey(t)
    return checked.refine { v in
      try bounds.allSatisfy { bound in
        switch bound {
        case .length(let op, let b):
          let length = try Scalar.helper("length", [v], [key], context.schema.bits)
          return Scalar.equal(try Scalar.binary(op, length, b, "Integer", "Integer"), .bool(true))
        case .compare(let op, let b):
          return Scalar.equal(try Scalar.binary(op, v, b, key, key), .bool(true))
        }
      }
    }
  }

  private static func buildNative(
    _ context: Context, _ t: TypeRef, _ budget: Int, _ bounds: [Bound]
  ) throws -> Gen<Value> {
    if case .named("List", let args) = t, args.count == 1 {
      let element = args[0]
      let limitCost = lengths(bounds).isEmpty ? budget - 1 : Swift.max(64, budget - 1)
      guard let cost = try minimum(context, element, limitCost) else {
        return Gen.constant(Value.list([])).refine { _ in try lengthAllowed(0, bounds) }
      }
      return try lengthGenerator(bounds, (budget - 1) / cost).bind { count in
        if count == 0 { return .constant(.list([])) }
        return Gens.vector(
          count, try build(context, element, Swift.max(cost, (budget - 1) / count), [])
        ).map { .list($0) }
      }
    }
    if case .named(let kind, let args) = t, args.count == 1,
      kind == "Optional" || kind == "Nullable"
    {
      let absent = Gen.constant(Value.presence(kind: kind, value: nil))
      if try minimum(context, args[0], budget - 1) == nil { return absent }
      return Gens.oneOf([
        absent,
        try build(context, args[0], budget - 1, []).map { .presence(kind: kind, value: $0) },
      ])
    }
    guard let raw = try Schema.constructors(t, context.schema) else {
      return try scalar(context, t, bounds)
    }
    var choices = [Gen<Value>]()
    for c0 in raw {
      for c in Schema.witnessInstances(c0) {
        if let shares = try allocation(context, c.fields, budget - 1 - c.witnessValues.count) {
          choices.append(constructorGen(context, c, shares))
        }
      }
    }
    let schema = context.schema
    return Gens.oneOf(choices).map { try canonical(t, $0) }.constrain(context.attempts) {
      try accepted($0, t, schema)
    }
  }

  private static func constructorGen(_ context: Context, _ c: Schema.Constructor, _ shares: [Int])
    -> Gen<Value>
  {
    func fields(_ remaining: ArraySlice<((String, TypeRef), Int)>, _ values: [Value]) throws -> Gen<
      Value
    > {
      guard let (field, share) = remaining.first else {
        return .constant(.data(c.tag, values + c.witnessValues))
      }
      let position = values.count + 1
      let hints = try c.generators[position].map { try $0(context.schema, c.arguments, values) }
      let bounds =
        (hints?.bounds.map { Bound.compare($0.0, $0.1) } ?? [])
        + (hints?.lengths.map { Bound.length($0.0, $0.1) } ?? [])
      let native = try build(context, field.1, share, bounds)
      let g =
        factory(context, field.1) != nil ? native : Gens.withExamples(hints?.hints ?? [], native)
      return g.bind { v in try fields(remaining.dropFirst(), values + [v]) }
    }
    return Gen { seed, size in
      try fields(Array(zip(c.fields, shares))[...], []).generate(seed, size)
    }
  }

  // MARK: Indexed families

  private indirect enum Term {
    case constant(BigInt)
    case field(Int)
    case op(String, Term, Term)
  }

  private static func tokens(_ text: String) -> [String] {
    text.split(separator: " ").map(String.init)
  }

  private static func parse(_ tokens: ArraySlice<String>) throws -> (Term, ArraySlice<String>) {
    guard let t = tokens.first else { throw Fail.with("InvalidIndexTerm") }
    let rest = tokens.dropFirst()
    if t.hasPrefix("c"), let n = BigInt(String(t.dropFirst())) { return (.constant(n), rest) }
    if t.hasPrefix("f"), let i = Int(t.dropFirst()) { return (.field(i), rest) }
    let (a, next) = try parse(rest)
    let (b, after) = try parse(next)
    return (.op(t, a, b), after)
  }

  private static func termFields(_ term: Term) -> [Int] {
    switch term {
    case .constant: return []
    case .field(let i): return [i]
    case .op(_, let a, let b): return termFields(a) + termFields(b)
    }
  }

  private static func evaluate(_ term: Term, _ assigned: [Int: BigInt]) -> BigInt? {
    switch term {
    case .constant(let n): return n
    case .field(let i): return assigned[i]
    case .op(let op, let a, let b):
      guard let x = evaluate(a, assigned), let y = evaluate(b, assigned) else { return nil }
      switch op {
      case "+": return x + y
      case "-" where x >= y: return x - y
      case "*": return x * y
      case "div" where y.signum > 0: return x / y
      case "mod" where y.signum > 0: return x % y
      case "^" where y.signum >= 0 && y <= 64: return x.power(y.exactly(Int.self)!)
      default: return nil
      }
    }
  }

  private struct Equation {
    let term: Term
    let guards: [(String, Term, Term)]
    let positions: [Int]
  }

  private static func equation(_ texts: [String]) throws -> Equation {
    guard let text = texts.first else { throw Fail.with("InvalidIndexTerm") }
    let (term, _) = try parse(tokens(text)[...])
    let parsed = try texts.dropFirst().map { g -> (String, Term, Term) in
      let parts = tokens(g)
      guard let op = parts.first else { throw Fail.with("InvalidIndexGuard", g) }
      let (a, next) = try parse(parts.dropFirst())
      let (b, _) = try parse(next)
      return (op, a, b)
    }
    let all = termFields(term) + parsed.flatMap { termFields($0.1) + termFields($0.2) }
    return Equation(term: term, guards: parsed, positions: Array(Set(all)).sorted())
  }

  private static func holds(_ g: (String, Term, Term), _ assigned: [Int: BigInt]) -> Bool {
    guard let x = evaluate(g.1, assigned), let y = evaluate(g.2, assigned) else { return false }
    return g.0 == "==" ? x == y : x >= y
  }

  private struct Level: Hashable {
    let type: TypeRef
    let index: Int
  }

  /// An indexed family's value whose index is the target (or, for a negative
  /// target, any of its smallest reachable indices).
  public static func indexed(
    _ context: Context, _ t: TypeRef, _ target: BigInt, _ equations: [String: [String]],
    _ budget: Int
  ) throws -> Gen<Value> {
    let parsed = try equations.mapValues(equation)
    func positions(_ c: Schema.Constructor) -> [Int] { parsed[c.tag]?.positions ?? [] }
    var all = [TypeRef: [Schema.Constructor]]()
    var order = [TypeRef]()
    var pending = [t]
    while let next = pending.first {
      pending.removeFirst()
      if all[next] != nil { continue }
      guard let cs = try Schema.constructors(next, context.schema)?.flatMap(Schema.witnessInstances)
      else {
        throw Fail.with("IndexedTypeRequiresData", Scalar.typeKey(next))
      }
      all[next] = cs
      order.append(next)
      pending = cs.flatMap { c in positions(c).map { c.fields[$0].1 } } + pending
    }
    var plain = [TypeRef: Int?]()
    for ft in order {
      for c in all[ft]! {
        for (i, field) in c.fields.enumerated() where !positions(c).contains(i) {
          plain[field.1] = try minimum(context, field.1, 64)
        }
      }
    }
    let limitIndex = (BigInt.max(.zero, target).exactly(Int.self) ?? 0) + 16
    func assignments(_ c: Schema.Constructor, _ costs: [Level: Int]) -> [(
      Int, [Int: BigInt], [Int]
    )] {
      guard let eq = parsed[c.tag] else { return [] }
      let ok = c.fields.enumerated().allSatisfy { i, field in
        eq.positions.contains(i) || (plain[field.1] ?? nil) != nil
      }
      if !ok { return [] }
      let choices = eq.positions.map { i -> (Int, [Int]) in
        let ft = c.fields[i].1
        return (i, costs.keys.filter { $0.type == ft }.map { $0.index }.sorted())
      }
      func assign(_ choices: ArraySlice<(Int, [Int])>, _ assigned: [Int: BigInt]) -> [[Int: BigInt]]
      {
        let ready = eq.guards.filter { g in
          (termFields(g.1) + termFields(g.2)).allSatisfy { assigned[$0] != nil }
        }
        if !ready.allSatisfy({ holds($0, assigned) }) { return [] }
        guard let (i, values) = choices.first else { return [assigned] }
        return values.flatMap { v in
          assign(choices.dropFirst(), assigned.merging([i: BigInt(v)]) { $1 })
        }
      }
      var result = [(Int, [Int: BigInt], [Int])]()
      for assigned in assign(choices[...], [:]) {
        guard let value = evaluate(eq.term, assigned), value.signum >= 0,
          value <= BigInt(limitIndex)
        else { continue }
        let required = c.fields.enumerated().map { i, field -> Int in
          if let k = assigned[i] {
            return costs[Level(type: field.1, index: k.exactly(Int.self)!)]!
          }
          return (plain[field.1] ?? nil)!
        }
        result.append((value.exactly(Int.self)!, assigned, required))
      }
      return result
    }
    var costs = [Level: Int]()
    while true {
      var next = costs
      for ft in order {
        for c in all[ft]! {
          for (k, _, fields) in assignments(c, costs) {
            let cost = 1 + c.witnessValues.count + fields.reduce(0, +)
            let key = Level(type: ft, index: k)
            if let existing = next[key], existing <= cost { continue }
            next[key] = cost
          }
        }
      }
      if next == costs { break }
      costs = next
    }
    var solutions = [Level: [(Schema.Constructor, [Int: BigInt], [Int])]]()
    for ft in order {
      for c in all[ft]! {
        for (k, targets, fields) in assignments(c, costs) {
          solutions[Level(type: ft, index: k), default: []].append((c, targets, fields))
        }
      }
    }
    let levels: [Int]
    if target.isNegative {
      levels = Array(costs.keys.filter { $0.type == t }.map { $0.index }.sorted().prefix(6))
    } else {
      let k = target.exactly(Int.self) ?? -1
      levels = costs[Level(type: t, index: k)] != nil ? [k] : []
    }
    let schema = context.schema
    func generate(_ ft: TypeRef, _ k: Int, _ share: Int) -> Gen<Value> {
      let choices = (solutions[Level(type: ft, index: k)] ?? []).filter { c, _, fieldCosts in
        1 + c.witnessValues.count + fieldCosts.reduce(0, +) <= share
      }
      return Gens.oneOf(choices.map { Gen.constant($0) }).bind { choice in
        let (c, targets, fieldCosts) = choice
        let count = fieldCosts.count
        let extra = share - 1 - c.witnessValues.count - fieldCosts.reduce(0, +)
        let children = try zip(c.fields, fieldCosts).enumerated().map { i, pair -> Gen<Value> in
          let ((_, childType), cost) = pair
          let childShare = cost + (count > 0 ? extra / count + (i < extra % count ? 1 : 0) : 0)
          if let index = targets[i] {
            return generate(childType, index.exactly(Int.self)!, childShare)
          }
          return try build(context, childType, childShare, [])
        }
        return Gens.tuple(children).map { .data(c.tag, $0 + c.witnessValues) }
      }.constrain(context.attempts) { try accepted($0, ft, schema) }
    }
    if levels.isEmpty {
      if target.isNegative { throw Fail.with("NoIndexedGenerator", Scalar.typeKey(t)) }
      return .empty
    }
    return Gens.oneOf(levels.map { Gen.constant($0) }).bind { k in
      generate(t, k, Swift.max(budget, costs[Level(type: t, index: k)]!))
    }
  }

  /// A bound on an input.
  public static func compareBound(_ op: String, _ value: Value) -> Bound { .compare(op, value) }

  /// A bound on an input's length.
  public static func lengthBound(_ op: String, _ value: Value) -> Bound { .length(op, value) }

  /// An indexed family's target index and each constructor's index terms.
  public struct IndexTarget {
    let target: BigInt
    let equations: [String: [String]]
  }

  /// No index to aim at.
  public static func noIndex() -> IndexTarget? { nil }

  /// An indexed family's target index and each constructor's index terms.
  public static func index(_ target: Value, _ tags: [String], _ terms: [[String]]) throws
    -> IndexTarget?
  {
    guard case .int(let n) = target else { throw Fail.with("IntegerRequired", "index target") }
    return IndexTarget(target: n, equations: Dictionary(zip(tags, terms), uniquingKeysWith: { $1 }))
  }

  /// The generator of an input of a type: native factories first, then the
  /// type's structure within a budget that grows with the size.
  public static func generator(
    _ context: Context, _ t: TypeRef, _ bounds: [Bound], _ witnesses: [Value], _ index: IndexTarget?
  ) -> Gen<Value> {
    Gen.sized { size in
      if let f = factory(context, t) { return try custom(context, t, size + 1, bounds, f) }
      let limit = ([64] + witnesses.map(valueNodes)).max()!
      guard let least = try minimum(context, t, limit) else {
        throw Fail.with("NoStructuralGenerator", Scalar.typeKey(t))
      }
      let budget = Swift.max(least, size + 1)
      if let target = index {
        return try indexed(context, t, target.target, target.equations, budget)
      }
      return Gens.withExamples(witnesses, try build(context, t, budget, bounds))
    }
  }
}
