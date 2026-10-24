// What typed definitions use: LawSpec's integer semantics on Swift's native
// integers (checked, failing as the dynamic code does), text by code point,
// and the sequence and collection helpers, over the native types the
// generated code already uses (arrays, optionals, SortedMap and SortedSet),
// so a typed definition never copies a value to call another.
// ref:DEC-typed-native-definitions ref:DEC-portable-exact-arithmetic

public enum Typed {
  /// An integer outside its type, as the dynamic code reports it.
  public static func outOfRange(_ name: String, _ value: BigInt) -> LawSpecError {
    Fail.with("IntegerOutOfRange", "\(name) \(value)")
  }

  /// A branch the checker proved unreachable.
  public static func unreachable<T>() throws -> T {
    throw Fail.with("Unreachable", "unreachable branch reached")
  }

  /// The failure a branch the checker proved unreachable raises.
  public static func unreachableFailure() -> LawSpecError {
    Fail.with("Unreachable", "unreachable branch reached")
  }

  /// A failure the typed code raises: the same error the dynamic code raises.
  public static func raiseFailure<T>(_ ability: String, _ failure: Value) throws -> T {
    throw RaisedFailure(ability, failure)
  }

  /// An exact result narrowed to a bounded type, failing outside it.
  public static func narrow<T: FixedWidthInteger>(
    _ name: String, _ value: BigInt, _ type: T.Type = T.self
  ) throws -> T {
    guard let n = value.exactly(T.self) else { throw outOfRange(name, value) }
    return n
  }

  /// A bounded native integer, exactly.
  public static func exact<T: BinaryInteger>(_ value: T) -> BigInt { BigInt(value) }

  /// Checked addition on one bounded type: an overflow is the same failure.
  public static func add<T: FixedWidthInteger>(_ name: String, _ a: T, _ b: T) throws -> T {
    let (r, overflow) = a.addingReportingOverflow(b)
    if overflow { throw outOfRange(name, BigInt(a) + BigInt(b)) }
    return r
  }

  public static func subtract<T: FixedWidthInteger>(_ name: String, _ a: T, _ b: T) throws -> T {
    let (r, overflow) = a.subtractingReportingOverflow(b)
    if overflow { throw outOfRange(name, BigInt(a) - BigInt(b)) }
    return r
  }

  public static func multiply<T: FixedWidthInteger>(_ name: String, _ a: T, _ b: T) throws -> T {
    let (r, overflow) = a.multipliedReportingOverflow(by: b)
    if overflow { throw outOfRange(name, BigInt(a) * BigInt(b)) }
    return r
  }

  /// Exact quotient, truncated towards zero; dividing by zero fails.
  public static func quotient(_ a: BigInt, _ b: BigInt) throws -> BigInt {
    if b.isZero { throw Fail.with("InvalidExactOperation", "quot") }
    return a / b
  }

  /// Exact remainder, with the dividend's sign; dividing by zero fails.
  public static func remainder(_ a: BigInt, _ b: BigInt) throws -> BigInt {
    if b.isZero { throw Fail.with("InvalidExactOperation", "rem") }
    return a % b
  }

  public static func power(_ a: BigInt, _ b: BigInt) throws -> BigInt {
    guard !b.isNegative, let e = b.exactly(Int32.self) else {
      throw Fail.with("InvalidExactOperation", "pow")
    }
    return a.power(Int(e))
  }

  /// LawSpec's equality of two native values.
  public static func equal<T: Portable>(_ a: T, _ b: T) -> Bool { T.portableEqual(a, b) }

  /// The portable order of two native values: text by code point.
  public static func compare<T: Portable>(_ a: T, _ b: T) -> Int { T.portableCompare(a, b) }

  // MARK: Text, by code point

  public static func textLength(_ s: String) -> BigInt { BigInt(s.unicodeScalars.count) }

  private static func clamp(_ value: BigInt, _ lo: Int, _ hi: Int) -> Int {
    if value < BigInt(lo) { return lo }
    if value > BigInt(hi) { return hi }
    return value.exactly(Int.self)!
  }

  private static func window(_ from: BigInt, _ until: BigInt, _ count: Int) -> (Int, Int) {
    let i = clamp(from, 0, count)
    return (i, clamp(until, i, count))
  }

  public static func sliceText(_ s: String, _ from: BigInt, _ until: BigInt) -> String {
    let scalars = Array(s.unicodeScalars)
    let (i, j) = window(from, until, scalars.count)
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars[i..<j])
    return String(view)
  }

  public static func sliceBytes(_ s: [UInt8], _ from: BigInt, _ until: BigInt) -> [UInt8] {
    let (i, j) = window(from, until, s.count)
    return Array(s[i..<j])
  }

  public static func sliceList<T>(_ xs: PersistentList<T>, _ from: BigInt, _ until: BigInt)
    -> PersistentList<T>
  {
    let (i, j) = window(from, until, xs.count)
    return xs.slice(i, j)
  }

  public static func atList<T>(_ xs: PersistentList<T>, _ i: BigInt) -> T? {
    guard !i.isNegative, let k = i.exactly(Int.self) else { return nil }
    return xs.item(at: k)
  }

  public static func atBytes(_ xs: [UInt8], _ i: BigInt) -> UInt8? {
    guard !i.isNegative, let k = i.exactly(Int.self), k < xs.count else { return nil }
    return xs[k]
  }

  /// lo, lo + 1, ..., hi - 1.
  public static func range(_ lo: BigInt, _ hi: BigInt) -> PersistentList<BigInt> {
    var result = [BigInt]()
    var n = lo
    while n < hi {
      result.append(n)
      n += .one
    }
    return PersistentList(result)
  }

  public static func utf8(_ s: String) -> [UInt8] { Array(s.utf8) }
  public static func textOf(_ n: BigInt) -> String { n.description }
  public static func join(_ separator: String, _ parts: PersistentList<String>) -> String {
    parts.joined(separator: separator)
  }

  public static func startsWith(_ text: String, _ prefix: String) -> Bool {
    text.unicodeScalars.starts(with: prefix.unicodeScalars)
  }
  public static func endsWith(_ text: String, _ suffix: String) -> Bool {
    text.unicodeScalars.reversed().starts(with: suffix.unicodeScalars.reversed())
  }

  /// Whether a text holds a part, code point by code point.
  public static func contains(_ text: String, _ part: String) -> Bool {
    let t = Array(text.unicodeScalars.map { $0.value })
    let p = Array(part.unicodeScalars.map { $0.value })
    if p.isEmpty { return true }
    if p.count > t.count { return false }
    for i in 0...(t.count - p.count) where Array(t[i..<(i + p.count)]) == p { return true }
    return false
  }

  // MARK: Collections

  public static func keyValOf<E, K: Portable, V>(
    _ key: (E) -> K, _ value: (E) -> V, _ entries: PersistentList<E>
  ) -> SortedMap<K, V> {
    SortedMap(entries.map { (key($0), value($0)) })
  }

  /// A Set's items in the portable order.
  public static func items<T>(_ s: SortedSet<T>) -> PersistentList<T> { PersistentList(s.items) }
  public static func keys<K, V>(_ m: SortedMap<K, V>) -> PersistentList<K> {
    PersistentList(m.keys)
  }
  public static func values<K, V>(_ m: SortedMap<K, V>) -> PersistentList<V> {
    PersistentList(m.values)
  }
  public static func entries<K, V, E>(_ entry: (K, V) -> E, _ m: SortedMap<K, V>) -> PersistentList<
    E
  > { PersistentList(m.entries.map { entry($0.key, $0.value) }) }

  // MARK: Failures across the typed boundary

  /// attempt: right of the body's value, or left of the failure raised with
  /// this ability, converted to its native type.
  public static func attempt<E, A>(
    _ ability: String, _ failure: (Value) throws -> E, _ body: () throws -> A
  ) throws -> Either<E, A> {
    do {
      return .right(try body())
    } catch let raised as RaisedFailure where raised.ability == ability {
      return .left(try failure(raised.failure))
    }
  }

  /// An operation's typed throw, raised as the failure the dynamic code raises.
  public static func performed<A, E: Error>(
    _ ability: String, _ failure: (E) throws -> Value, _ body: () throws(E) -> A
  ) throws -> A {
    do {
      return try body()
    } catch {
      throw RaisedFailure(ability, try failure(error))
    }
  }
}
