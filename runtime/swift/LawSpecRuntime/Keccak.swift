// The Keccak-f[1600] permutation and the FIPS 202 functions built on it.
// CryptoKit has SHA3-256 but no SHAKE, and the fallbacks for ML-KEM, ML-DSA
// and SLH-DSA need SHAKE128, SHAKE256 and SHA3-512 as incremental sponges.
// ref:DEC-typed-core-boundary

/// A Keccak sponge: absorb bytes, then squeeze any number of bytes.
/// CryptoKit is not used here: it has no SHAKE and no incremental squeeze.
struct KeccakSponge {
  private var state = [UInt64](repeating: 0, count: 25)
  /// The rate in bytes: 168 for SHAKE128, 136 for SHAKE256 and SHA3-256, 72 for SHA3-512.
  private let rate: Int
  /// The domain separation byte: 0x1F for SHAKE, 0x06 for SHA3.
  private let suffix: UInt8
  private var position = 0
  private var squeezing = false

  init(rate: Int, suffix: UInt8) {
    self.rate = rate
    self.suffix = suffix
  }

  static func shake128() -> KeccakSponge { KeccakSponge(rate: 168, suffix: 0x1F) }
  static func shake256() -> KeccakSponge { KeccakSponge(rate: 136, suffix: 0x1F) }

  private static let roundConstants: [UInt64] = [
    0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808A, 0x8000_0000_8000_8000,
    0x0000_0000_0000_808B, 0x0000_0000_8000_0001, 0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
    0x0000_0000_0000_008A, 0x0000_0000_0000_0088, 0x0000_0000_8000_8009, 0x0000_0000_8000_000A,
    0x0000_0000_8000_808B, 0x8000_0000_0000_008B, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
    0x8000_0000_0000_8002, 0x8000_0000_0000_0080, 0x0000_0000_0000_800A, 0x8000_0000_8000_000A,
    0x8000_0000_8000_8081, 0x8000_0000_0000_8080, 0x0000_0000_8000_0001, 0x8000_0000_8000_8008,
  ]

  /// Keccak-f[1600] on 25 locals, unrolled: fast even in debug builds.
  private mutating func permute() {
    var a0 = state[0]
    var a1 = state[1]
    var a2 = state[2]
    var a3 = state[3]
    var a4 = state[4]
    var a5 = state[5]
    var a6 = state[6]
    var a7 = state[7]
    var a8 = state[8]
    var a9 = state[9]
    var a10 = state[10]
    var a11 = state[11]
    var a12 = state[12]
    var a13 = state[13]
    var a14 = state[14]
    var a15 = state[15]
    var a16 = state[16]
    var a17 = state[17]
    var a18 = state[18]
    var a19 = state[19]
    var a20 = state[20]
    var a21 = state[21]
    var a22 = state[22]
    var a23 = state[23]
    var a24 = state[24]
    for round in 0..<24 {
      let c0 = a0 ^ a5 ^ a10 ^ a15 ^ a20
      let c1 = a1 ^ a6 ^ a11 ^ a16 ^ a21
      let c2 = a2 ^ a7 ^ a12 ^ a17 ^ a22
      let c3 = a3 ^ a8 ^ a13 ^ a18 ^ a23
      let c4 = a4 ^ a9 ^ a14 ^ a19 ^ a24
      let d0 = c4 ^ ((c1 << 1) | (c1 >> 63))
      let d1 = c0 ^ ((c2 << 1) | (c2 >> 63))
      let d2 = c1 ^ ((c3 << 1) | (c3 >> 63))
      let d3 = c2 ^ ((c4 << 1) | (c4 >> 63))
      let d4 = c3 ^ ((c0 << 1) | (c0 >> 63))
      a0 ^= d0
      a1 ^= d1
      a2 ^= d2
      a3 ^= d3
      a4 ^= d4
      a5 ^= d0
      a6 ^= d1
      a7 ^= d2
      a8 ^= d3
      a9 ^= d4
      a10 ^= d0
      a11 ^= d1
      a12 ^= d2
      a13 ^= d3
      a14 ^= d4
      a15 ^= d0
      a16 ^= d1
      a17 ^= d2
      a18 ^= d3
      a19 ^= d4
      a20 ^= d0
      a21 ^= d1
      a22 ^= d2
      a23 ^= d3
      a24 ^= d4
      let b0 = a0
      let b16 = (a5 << 36) | (a5 >> 28)
      let b7 = (a10 << 3) | (a10 >> 61)
      let b23 = (a15 << 41) | (a15 >> 23)
      let b14 = (a20 << 18) | (a20 >> 46)
      let b10 = (a1 << 1) | (a1 >> 63)
      let b1 = (a6 << 44) | (a6 >> 20)
      let b17 = (a11 << 10) | (a11 >> 54)
      let b8 = (a16 << 45) | (a16 >> 19)
      let b24 = (a21 << 2) | (a21 >> 62)
      let b20 = (a2 << 62) | (a2 >> 2)
      let b11 = (a7 << 6) | (a7 >> 58)
      let b2 = (a12 << 43) | (a12 >> 21)
      let b18 = (a17 << 15) | (a17 >> 49)
      let b9 = (a22 << 61) | (a22 >> 3)
      let b5 = (a3 << 28) | (a3 >> 36)
      let b21 = (a8 << 55) | (a8 >> 9)
      let b12 = (a13 << 25) | (a13 >> 39)
      let b3 = (a18 << 21) | (a18 >> 43)
      let b19 = (a23 << 56) | (a23 >> 8)
      let b15 = (a4 << 27) | (a4 >> 37)
      let b6 = (a9 << 20) | (a9 >> 44)
      let b22 = (a14 << 39) | (a14 >> 25)
      let b13 = (a19 << 8) | (a19 >> 56)
      let b4 = (a24 << 14) | (a24 >> 50)
      a0 = b0 ^ (~b1 & b2)
      a1 = b1 ^ (~b2 & b3)
      a2 = b2 ^ (~b3 & b4)
      a3 = b3 ^ (~b4 & b0)
      a4 = b4 ^ (~b0 & b1)
      a5 = b5 ^ (~b6 & b7)
      a6 = b6 ^ (~b7 & b8)
      a7 = b7 ^ (~b8 & b9)
      a8 = b8 ^ (~b9 & b5)
      a9 = b9 ^ (~b5 & b6)
      a10 = b10 ^ (~b11 & b12)
      a11 = b11 ^ (~b12 & b13)
      a12 = b12 ^ (~b13 & b14)
      a13 = b13 ^ (~b14 & b10)
      a14 = b14 ^ (~b10 & b11)
      a15 = b15 ^ (~b16 & b17)
      a16 = b16 ^ (~b17 & b18)
      a17 = b17 ^ (~b18 & b19)
      a18 = b18 ^ (~b19 & b15)
      a19 = b19 ^ (~b15 & b16)
      a20 = b20 ^ (~b21 & b22)
      a21 = b21 ^ (~b22 & b23)
      a22 = b22 ^ (~b23 & b24)
      a23 = b23 ^ (~b24 & b20)
      a24 = b24 ^ (~b20 & b21)
      a0 ^= KeccakSponge.roundConstants[round]
    }
    state[0] = a0
    state[1] = a1
    state[2] = a2
    state[3] = a3
    state[4] = a4
    state[5] = a5
    state[6] = a6
    state[7] = a7
    state[8] = a8
    state[9] = a9
    state[10] = a10
    state[11] = a11
    state[12] = a12
    state[13] = a13
    state[14] = a14
    state[15] = a15
    state[16] = a16
    state[17] = a17
    state[18] = a18
    state[19] = a19
    state[20] = a20
    state[21] = a21
    state[22] = a22
    state[23] = a23
    state[24] = a24
  }

  private mutating func xorByte(_ byte: UInt8, at index: Int) {
    state[index >> 3] ^= UInt64(byte) << (UInt64(index & 7) * 8)
  }

  private func byte(at index: Int) -> UInt8 {
    UInt8(truncatingIfNeeded: state[index >> 3] >> (UInt64(index & 7) * 8))
  }

  /// Absorb more input; it must come before any squeeze.
  mutating func absorb(_ bytes: [UInt8]) {
    precondition(!squeezing, "absorb after squeeze")
    var index = 0
    while index < bytes.count {
      // Absorb up to the end of the block, then permute.
      let take = min(rate - position, bytes.count - index)
      var position = self.position
      state.withUnsafeMutableBufferPointer { lanes in
        bytes.withUnsafeBufferPointer { input in
          for i in index..<(index + take) {
            lanes[position >> 3] ^= UInt64(input[i]) << (UInt64(position & 7) * 8)
            position += 1
          }
        }
      }
      index += take
      if position == rate {
        permute()
        position = 0
      }
      self.position = position
    }
  }

  mutating func absorb(_ byte: UInt8) {
    absorb([byte])
  }

  /// The next bytes of output.
  mutating func squeeze(_ count: Int) -> [UInt8] {
    if !squeezing {
      xorByte(suffix, at: position)
      xorByte(0x80, at: rate - 1)
      permute()
      position = 0
      squeezing = true
    }
    var out = [UInt8](repeating: 0, count: max(0, count))
    for i in 0..<out.count {
      if position == rate {
        permute()
        position = 0
      }
      out[i] = byte(at: position)
      position += 1
    }
    return out
  }
}

/// The FIPS 202 functions, over byte arrays.
enum Keccak {
  static func shake256(_ message: [UInt8], _ count: Int) -> [UInt8] {
    var sponge = KeccakSponge.shake256()
    sponge.absorb(message)
    return sponge.squeeze(count)
  }

  static func shake128(_ message: [UInt8], _ count: Int) -> [UInt8] {
    var sponge = KeccakSponge.shake128()
    sponge.absorb(message)
    return sponge.squeeze(count)
  }

  static func sha3_256(_ message: [UInt8]) -> [UInt8] {
    var sponge = KeccakSponge(rate: 136, suffix: 0x06)
    sponge.absorb(message)
    return sponge.squeeze(32)
  }

  static func sha3_512(_ message: [UInt8]) -> [UInt8] {
    var sponge = KeccakSponge(rate: 72, suffix: 0x06)
    sponge.absorb(message)
    return sponge.squeeze(64)
  }
}
