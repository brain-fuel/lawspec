// LawSpec's arbitrary-precision integer. Swift's standard library has none,
// and the runtime takes no package dependencies, so it is here: a sign and a
// magnitude of 64-bit words, least significant first, with no high zero word.
// ref:DEC-swift-runtime-from-scratch ref:DEC-portable-exact-arithmetic

/// An integer of any size. Division truncates towards zero, as LawSpec's
/// `quot` and `rem` do; shifts and bitwise operators act on the two's
/// complement form, as on a native integer.
public struct BigInt: Sendable, Hashable, Comparable, CustomStringConvertible,
  ExpressibleByIntegerLiteral
{
  /// The magnitude, least significant word first, without high zero words.
  @usableFromInline var words: [UInt64]
  /// Whether the integer is below zero; zero is never negative.
  @usableFromInline var negative: Bool

  @usableFromInline init(words: [UInt64], negative: Bool) {
    var trimmed = words
    while let last = trimmed.last, last == 0 { trimmed.removeLast() }
    self.words = trimmed
    self.negative = trimmed.isEmpty ? false : negative
  }

  public static let zero = BigInt(words: [], negative: false)
  public static let one = BigInt(words: [1], negative: false)

  public init(integerLiteral value: Int) { self.init(value) }

  public init(_ value: Int) {
    if value >= 0 {
      self.init(words: [UInt64(value)], negative: false)
    } else {
      self.init(words: [UInt64(bitPattern: Int64(value)).twosComplementMagnitude], negative: true)
    }
  }

  public init<T: BinaryInteger>(_ value: T) {
    if value < 0 {
      // Magnitude of a negative value: complement the two's complement words.
      let positive = BigInt(words: value.words.map { UInt64($0) }, negative: false)
      let width = value.bitWidth
      let modulus = BigInt.one << width
      self = -(modulus - positive.truncatedTo(bits: width))
    } else {
      self.init(words: value.words.map { UInt64($0) }, negative: false)
    }
  }

  /// The integer of decimal digits, with an optional sign.
  public init?(_ text: String) { self.init(text, radix: 10) }

  /// The integer of digits in a radix from 2 to 36, with an optional sign.
  public init?(_ text: String, radix: Int) {
    guard radix >= 2 && radix <= 36 else { return nil }
    var digits = Substring(text)
    var negative = false
    if let first = digits.first, first == "-" || first == "+" {
      negative = first == "-"
      digits = digits.dropFirst()
    }
    guard !digits.isEmpty else { return nil }
    var result = BigInt.zero
    // Digits are taken in chunks that fit a word, then folded in.
    let chunk = radix == 10 ? 19 : 8
    var power: UInt64 = 1
    for _ in 0..<chunk { power *= UInt64(radix) }
    var accumulator: UInt64 = 0
    var count = 0
    for character in digits {
      guard let digit = character.hexDigitValue ?? character.letterValue, digit < radix else {
        return nil
      }
      accumulator = accumulator * UInt64(radix) + UInt64(digit)
      count += 1
      if count == chunk {
        result = result.multipliedAdding(power, accumulator)
        accumulator = 0
        count = 0
      }
    }
    if count > 0 {
      var scale: UInt64 = 1
      for _ in 0..<count { scale *= UInt64(radix) }
      result = result.multipliedAdding(scale, accumulator)
    }
    result.negative = negative && !result.words.isEmpty
    self = result
  }

  /// self * factor + addend, on the magnitude.
  private func multipliedAdding(_ factor: UInt64, _ addend: UInt64) -> BigInt {
    var result = [UInt64]()
    result.reserveCapacity(words.count + 1)
    var carry = addend
    for word in words {
      let (high, low) = word.multipliedFullWidth(by: factor)
      let (sum, overflow) = low.addingReportingOverflow(carry)
      result.append(sum)
      carry = high &+ (overflow ? 1 : 0)
    }
    if carry != 0 { result.append(carry) }
    return BigInt(words: result, negative: negative)
  }

  // MARK: Properties

  public var isZero: Bool { words.isEmpty }
  /// -1, 0 or 1.
  public var signum: Int { words.isEmpty ? 0 : (negative ? -1 : 1) }
  public var isNegative: Bool { negative }
  public var isEven: Bool { words.isEmpty || words[0] & 1 == 0 }
  public var magnitude: BigInt { BigInt(words: words, negative: false) }
  /// The number of bits of the magnitude: 0 for zero.
  public var bitLength: Int {
    guard let last = words.last else { return 0 }
    return (words.count - 1) * 64 + (64 - last.leadingZeroBitCount)
  }

  /// The value as a fixed-width integer, if it fits.
  public func exactly<T: FixedWidthInteger>(_ type: T.Type) -> T? {
    guard bitLength <= T.bitWidth else { return nil }
    if words.isEmpty { return 0 }
    if negative {
      guard T.isSigned else { return nil }
      // The magnitude of T.min is 2^(width-1).
      if bitLength == T.bitWidth {
        return self == BigInt(T.min) ? T.min : nil
      }
      var value: T = 0
      for (i, word) in words.enumerated() { value |= T(truncatingIfNeeded: word) << (i * 64) }
      return 0 - value
    }
    if T.isSigned && bitLength == T.bitWidth { return nil }
    var value: T = 0
    for (i, word) in words.enumerated() { value |= T(truncatingIfNeeded: word) << (i * 64) }
    return value
  }

  /// The low bits of the two's complement form, as a fixed-width integer.
  public func truncated<T: FixedWidthInteger>(_ type: T.Type) -> T {
    let low = truncatedTo(bits: T.bitWidth)
    var value: T = 0
    for (i, word) in low.words.enumerated() where i * 64 < T.bitWidth {
      value |= T(truncatingIfNeeded: word) << (i * 64)
    }
    return value
  }

  /// The value modulo 2^bits, as a non-negative integer.
  func truncatedTo(bits: Int) -> BigInt {
    let modulus = BigInt.one << bits
    var r = self % modulus
    if r.negative { r = r + modulus }
    return r
  }

  /// The nearest Double, rounding the magnitude's leading bits.
  public var doubleValue: Double {
    var result = 0.0
    for word in words.reversed() { result = result * 18446744073709551616.0 + Double(word) }
    return negative ? -result : result
  }

  // MARK: Magnitudes

  private static func compareMagnitudes(_ a: [UInt64], _ b: [UInt64]) -> Int {
    if a.count != b.count { return a.count < b.count ? -1 : 1 }
    var i = a.count - 1
    while i >= 0 {
      if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
      i -= 1
    }
    return 0
  }

  private static func addMagnitudes(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
    let (long, short) = a.count >= b.count ? (a, b) : (b, a)
    var result = [UInt64]()
    result.reserveCapacity(long.count + 1)
    var carry: UInt64 = 0
    for i in 0..<long.count {
      let (s1, o1) = long[i].addingReportingOverflow(i < short.count ? short[i] : 0)
      let (s2, o2) = s1.addingReportingOverflow(carry)
      result.append(s2)
      carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
    }
    if carry != 0 { result.append(carry) }
    return result
  }

  /// a - b, where a's magnitude is at least b's.
  private static func subtractMagnitudes(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
    var result = [UInt64]()
    result.reserveCapacity(a.count)
    var borrow: UInt64 = 0
    for i in 0..<a.count {
      let (d1, o1) = a[i].subtractingReportingOverflow(i < b.count ? b[i] : 0)
      let (d2, o2) = d1.subtractingReportingOverflow(borrow)
      result.append(d2)
      borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
    }
    return result
  }

  private static func multiplyMagnitudes(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
    if a.isEmpty || b.isEmpty { return [] }
    var result = [UInt64](repeating: 0, count: a.count + b.count)
    for i in 0..<a.count {
      var carry: UInt64 = 0
      let x = a[i]
      if x == 0 { continue }
      for j in 0..<b.count {
        let (high, low) = x.multipliedFullWidth(by: b[j])
        let (s1, o1) = low.addingReportingOverflow(result[i + j])
        let (s2, o2) = s1.addingReportingOverflow(carry)
        result[i + j] = s2
        carry = high &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
      }
      result[i + b.count] = carry
    }
    return result
  }

  /// Divide a magnitude by one word: the quotient and the remainder.
  private static func divideByWord(_ a: [UInt64], _ divisor: UInt64) -> ([UInt64], UInt64) {
    var quotient = [UInt64](repeating: 0, count: a.count)
    var remainder: UInt64 = 0
    var i = a.count - 1
    while i >= 0 {
      let (q, r) = divisor.dividingFullWidth((remainder, a[i]))
      quotient[i] = q
      remainder = r
      i -= 1
    }
    return (quotient, remainder)
  }

  /// Knuth's algorithm D on magnitudes: the quotient and the remainder.
  private static func divideMagnitudes(_ a: [UInt64], _ b: [UInt64]) -> ([UInt64], [UInt64]) {
    if compareMagnitudes(a, b) < 0 { return ([], a) }
    if b.count == 1 {
      let (q, r) = divideByWord(a, b[0])
      return (q, r == 0 ? [] : [r])
    }
    let shift = b[b.count - 1].leadingZeroBitCount
    let v = shiftLeftWords(b, shift)
    var u = shiftLeftWords(a, shift)
    if u.count == a.count { u.append(0) }
    let n = v.count
    let m = u.count - n
    var q = [UInt64](repeating: 0, count: m)
    let vTop = v[n - 1]
    let vNext = v[n - 2]
    var j = m - 1
    while j >= 0 {
      // Estimate the quotient word from the top two words.
      var qhat: UInt64
      var rhat: UInt64
      if u[j + n] >= vTop {
        qhat = UInt64.max
        let (r, overflow) = u[j + n - 1].addingReportingOverflow(vTop)
        rhat = r
        if overflow {
          qhat = UInt64.max
        } else {
          while true {
            let (high, low) = qhat.multipliedFullWidth(by: vNext)
            if high > rhat || (high == rhat && low > u[j + n - 2]) {
              qhat -= 1
              let (r2, o2) = rhat.addingReportingOverflow(vTop)
              rhat = r2
              if o2 { break }
            } else {
              break
            }
          }
        }
      } else {
        (qhat, rhat) = vTop.dividingFullWidth((u[j + n], u[j + n - 1]))
        while true {
          let (high, low) = qhat.multipliedFullWidth(by: vNext)
          if high > rhat || (high == rhat && low > u[j + n - 2]) {
            qhat -= 1
            let (r2, o2) = rhat.addingReportingOverflow(vTop)
            rhat = r2
            if o2 { break }
          } else {
            break
          }
        }
      }
      // Multiply and subtract.
      var borrow: UInt64 = 0
      var carry: UInt64 = 0
      for i in 0..<n {
        let (high, low) = qhat.multipliedFullWidth(by: v[i])
        let (product, o1) = low.addingReportingOverflow(carry)
        carry = high &+ (o1 ? 1 : 0)
        let (d1, b1) = u[i + j].subtractingReportingOverflow(product)
        let (d2, b2) = d1.subtractingReportingOverflow(borrow)
        u[i + j] = d2
        borrow = (b1 ? 1 : 0) + (b2 ? 1 : 0)
      }
      let (d1, b1) = u[j + n].subtractingReportingOverflow(carry)
      let (d2, b2) = d1.subtractingReportingOverflow(borrow)
      u[j + n] = d2
      if b1 || b2 {
        // Add back: the estimate was one too large.
        qhat -= 1
        var c: UInt64 = 0
        for i in 0..<n {
          let (s1, o1) = u[i + j].addingReportingOverflow(v[i])
          let (s2, o2) = s1.addingReportingOverflow(c)
          u[i + j] = s2
          c = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        u[j + n] = u[j + n] &+ c
      }
      q[j] = qhat
      j -= 1
    }
    let remainder = shiftRightWords(Array(u[0..<n]), shift)
    return (q, remainder)
  }

  private static func shiftLeftWords(_ a: [UInt64], _ bits: Int) -> [UInt64] {
    if bits == 0 { return a }
    var result = [UInt64]()
    result.reserveCapacity(a.count + 1)
    var carry: UInt64 = 0
    for word in a {
      result.append((word << UInt64(bits)) | carry)
      carry = word >> UInt64(64 - bits)
    }
    if carry != 0 { result.append(carry) }
    return result
  }

  private static func shiftRightWords(_ a: [UInt64], _ bits: Int) -> [UInt64] {
    if bits == 0 { return a }
    var result = [UInt64](repeating: 0, count: a.count)
    for i in 0..<a.count {
      let next = i + 1 < a.count ? a[i + 1] << UInt64(64 - bits) : 0
      result[i] = (a[i] >> UInt64(bits)) | next
    }
    return result
  }

  // MARK: Arithmetic

  public static func + (a: BigInt, b: BigInt) -> BigInt {
    if a.negative == b.negative {
      return BigInt(words: addMagnitudes(a.words, b.words), negative: a.negative)
    }
    let c = compareMagnitudes(a.words, b.words)
    if c == 0 { return .zero }
    if c > 0 { return BigInt(words: subtractMagnitudes(a.words, b.words), negative: a.negative) }
    return BigInt(words: subtractMagnitudes(b.words, a.words), negative: b.negative)
  }

  public static prefix func - (a: BigInt) -> BigInt {
    BigInt(words: a.words, negative: !a.negative)
  }

  public static func - (a: BigInt, b: BigInt) -> BigInt { a + (-b) }

  public static func * (a: BigInt, b: BigInt) -> BigInt {
    BigInt(words: multiplyMagnitudes(a.words, b.words), negative: a.negative != b.negative)
  }

  public static func += (a: inout BigInt, b: BigInt) { a = a + b }
  public static func -= (a: inout BigInt, b: BigInt) { a = a - b }
  public static func *= (a: inout BigInt, b: BigInt) { a = a * b }

  /// The quotient truncated towards zero and the remainder with the
  /// dividend's sign. The divisor must not be zero.
  public func quotientAndRemainder(dividingBy divisor: BigInt) -> (
    quotient: BigInt, remainder: BigInt
  ) {
    precondition(!divisor.isZero, "BigInt division by zero")
    let (q, r) = BigInt.divideMagnitudes(words, divisor.words)
    return (
      BigInt(words: q, negative: negative != divisor.negative), BigInt(words: r, negative: negative)
    )
  }

  public static func / (a: BigInt, b: BigInt) -> BigInt {
    a.quotientAndRemainder(dividingBy: b).quotient
  }
  public static func % (a: BigInt, b: BigInt) -> BigInt {
    a.quotientAndRemainder(dividingBy: b).remainder
  }

  /// The quotient rounded towards negative infinity.
  public func floorDivided(by divisor: BigInt) -> BigInt {
    let (q, r) = quotientAndRemainder(dividingBy: divisor)
    return (!r.isZero && (r.negative != divisor.negative)) ? q - .one : q
  }

  /// self raised to a non-negative power.
  public func power(_ exponent: Int) -> BigInt {
    precondition(exponent >= 0, "BigInt negative exponent")
    var result = BigInt.one
    var base = self
    var e = exponent
    while e > 0 {
      if e & 1 == 1 { result = result * base }
      e >>= 1
      if e > 0 { base = base * base }
    }
    return result
  }

  /// The greatest common divisor, never negative.
  public static func gcd(_ a: BigInt, _ b: BigInt) -> BigInt {
    var x = a.magnitude
    var y = b.magnitude
    while !y.isZero {
      let r = x % y
      x = y
      y = r
    }
    return x
  }

  public static func min(_ a: BigInt, _ b: BigInt) -> BigInt { a <= b ? a : b }
  public static func max(_ a: BigInt, _ b: BigInt) -> BigInt { a >= b ? a : b }

  // MARK: Shifts and bits

  public static func << (a: BigInt, bits: Int) -> BigInt {
    if bits < 0 { return a >> (-bits) }
    if a.isZero || bits == 0 { return a }
    let whole = bits / 64
    let shifted = shiftLeftWords(a.words, bits % 64)
    return BigInt(words: [UInt64](repeating: 0, count: whole) + shifted, negative: a.negative)
  }

  /// An arithmetic shift: it rounds towards negative infinity.
  public static func >> (a: BigInt, bits: Int) -> BigInt {
    if bits < 0 { return a << (-bits) }
    if a.isZero || bits == 0 { return a }
    if a.negative {
      // floor(a / 2^bits) for a negative a.
      return -(((-a) - .one) >> bits) - .one
    }
    let whole = bits / 64
    if whole >= a.words.count { return .zero }
    return BigInt(words: shiftRightWords(Array(a.words[whole...]), bits % 64), negative: false)
  }

  /// Two's complement words of a given count, for bitwise operators.
  private func complementWords(_ count: Int) -> [UInt64] {
    var result = words + [UInt64](repeating: 0, count: Swift.max(0, count - words.count))
    if !negative { return result }
    // -m in two's complement: invert m - 1.
    var borrow: UInt64 = 1
    for i in 0..<result.count {
      let (d, o) = result[i].subtractingReportingOverflow(borrow)
      result[i] = ~d
      borrow = o ? 1 : 0
    }
    return result
  }

  private static func fromComplement(_ words: [UInt64], negative: Bool) -> BigInt {
    if !negative { return BigInt(words: words, negative: false) }
    var result = words.map { ~$0 }
    var carry: UInt64 = 1
    for i in 0..<result.count {
      let (s, o) = result[i].addingReportingOverflow(carry)
      result[i] = s
      carry = o ? 1 : 0
    }
    return BigInt(words: result, negative: true)
  }

  private static func bitwise(
    _ a: BigInt, _ b: BigInt, _ op: (UInt64, UInt64) -> UInt64, _ sign: (Bool, Bool) -> Bool
  ) -> BigInt {
    let count = Swift.max(a.words.count, b.words.count) + 1
    let x = a.complementWords(count)
    let y = b.complementWords(count)
    var result = [UInt64](repeating: 0, count: count)
    for i in 0..<count { result[i] = op(x[i], y[i]) }
    return fromComplement(result, negative: sign(a.negative, b.negative))
  }

  public static func & (a: BigInt, b: BigInt) -> BigInt { bitwise(a, b, { $0 & $1 }, { $0 && $1 }) }
  public static func | (a: BigInt, b: BigInt) -> BigInt { bitwise(a, b, { $0 | $1 }, { $0 || $1 }) }
  public static func ^ (a: BigInt, b: BigInt) -> BigInt { bitwise(a, b, { $0 ^ $1 }, { $0 != $1 }) }

  // MARK: Order and text

  public static func < (a: BigInt, b: BigInt) -> Bool { compare(a, b) < 0 }

  /// -1, 0 or 1.
  public static func compare(_ a: BigInt, _ b: BigInt) -> Int {
    if a.negative != b.negative { return a.negative ? -1 : 1 }
    let c = compareMagnitudes(a.words, b.words)
    return a.negative ? -c : c
  }

  public var description: String { toString(radix: 10) }

  /// The digits in a radix from 2 to 36, lowercase, with a leading minus.
  public func toString(radix: Int) -> String {
    if words.isEmpty { return "0" }
    let chunk = radix == 10 ? 19 : 8
    var divisor: UInt64 = 1
    for _ in 0..<chunk { divisor *= UInt64(radix) }
    var parts = [String]()
    var rest = words
    while !rest.isEmpty {
      let (q, r) = BigInt.divideByWord(rest, divisor)
      rest = q
      while let last = rest.last, last == 0 { rest.removeLast() }
      parts.append(String(r, radix: radix))
    }
    var text = negative ? "-" : ""
    text += parts.last ?? "0"
    for part in parts.dropLast().reversed() {
      text += String(repeating: "0", count: chunk - part.count) + part
    }
    return text
  }
}

extension UInt64 {
  /// The magnitude of this bit pattern read as a negative Int64.
  fileprivate var twosComplementMagnitude: UInt64 { (~self) &+ 1 }
}

extension Character {
  /// a to z as 10 to 35.
  fileprivate var letterValue: Int? {
    guard let ascii = asciiValue else { return nil }
    if ascii >= 97 && ascii <= 122 { return Int(ascii) - 87 }
    if ascii >= 65 && ascii <= 90 { return Int(ascii) - 55 }
    return nil
  }
}
