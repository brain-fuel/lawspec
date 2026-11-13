// BLAKE3 (the BLAKE3 specification, section 2) with its default 32-byte
// output: the hash, the keyed hash and key derivation, written from the
// specification and its reference implementation (CC0 1.0 or Apache-2.0).
// One thread, no SIMD; the official test vectors check every mode (the
// contracts-digest acceptance suite). CryptoKit has no BLAKE3.
// Source: https://github.com/BLAKE3-team/BLAKE3, vectors at commit
// ae3e8e6b3a5ae3190ca5d62820789b17886a0038; CC0 1.0 or Apache-2.0. ref:DEC-blake3-port

/// BLAKE3's three modes: LawSpec's blake3, blake3Keyed and blake3DeriveKey.
public enum Blake3 {
  private static let iv: [UInt32] = [
    0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab,
    0x5be0_cd19,
  ]
  private static let schedule = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]
  private static let chunkStart: UInt32 = 1
  private static let chunkEnd: UInt32 = 2
  private static let parent: UInt32 = 4
  private static let root: UInt32 = 8
  private static let keyedHash: UInt32 = 16
  private static let deriveKeyContext: UInt32 = 32
  private static let deriveKeyMaterial: UInt32 = 64

  /// Sixteen little-endian words of a block, zero padded to 64 bytes.
  private static func words(_ data: [UInt8], _ offset: Int, _ length: Int) -> [UInt32] {
    var result = [UInt32](repeating: 0, count: 16)
    for i in 0..<length {
      result[i / 4] |= UInt32(data[offset + i]) << UInt32(8 * (i % 4))
    }
    return result
  }

  private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
    (value >> count) | (value << (32 - count))
  }

  private static func mix(
    _ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt32, _ y: UInt32
  ) {
    state[a] = state[a] &+ state[b] &+ x
    state[d] = rotate(state[d] ^ state[a], 16)
    state[c] = state[c] &+ state[d]
    state[b] = rotate(state[b] ^ state[c], 12)
    state[a] = state[a] &+ state[b] &+ y
    state[d] = rotate(state[d] ^ state[a], 8)
    state[c] = state[c] &+ state[d]
    state[b] = rotate(state[b] ^ state[c], 7)
  }

  /// The first eight words of BLAKE3's compression: a chaining value.
  private static func compress(
    _ cv: [UInt32], _ block: [UInt32], _ counter: UInt64, _ length: Int, _ flags: UInt32
  ) -> [UInt32] {
    var state = cv + iv[0..<4]
    state.append(UInt32(truncatingIfNeeded: counter))
    state.append(UInt32(truncatingIfNeeded: counter >> 32))
    state.append(UInt32(length))
    state.append(flags)
    var m = block
    for round in 0..<7 {
      mix(&state, 0, 4, 8, 12, m[0], m[1])
      mix(&state, 1, 5, 9, 13, m[2], m[3])
      mix(&state, 2, 6, 10, 14, m[4], m[5])
      mix(&state, 3, 7, 11, 15, m[6], m[7])
      mix(&state, 0, 5, 10, 15, m[8], m[9])
      mix(&state, 1, 6, 11, 12, m[10], m[11])
      mix(&state, 2, 7, 8, 13, m[12], m[13])
      mix(&state, 3, 4, 9, 14, m[14], m[15])
      if round < 6 {
        let current = m
        m = schedule.map { current[$0] }
      }
    }
    return (0..<8).map { state[$0] ^ state[$0 + 8] }
  }

  /// A chunk's chaining value; its last block carries the extra flags.
  private static func chunk(
    _ key: [UInt32], _ mode: UInt32, _ data: [UInt8], _ index: Int, _ last: UInt32
  ) -> [UInt32] {
    let end = min(data.count, index * 1024 + 1024)
    var offset = index * 1024
    var cv = key
    var flags = mode | chunkStart
    while end - offset > 64 {
      cv = compress(cv, words(data, offset, 64), UInt64(index), 64, flags)
      flags = mode
      offset += 64
    }
    let length = end - offset
    return compress(
      cv, words(data, offset, length), UInt64(index), length, flags | chunkEnd | last)
  }

  /// The 32-byte output from a key of eight words and a mode's flag: the
  /// initial value and no flag hash, a key and KEYED_HASH hash under the
  /// key, and the two DERIVE_KEY flags derive a key. The chunks are merged
  /// as the reference implementation merges them: a stack of subtree
  /// chaining values, one subtree closed per trailing zero of the chunk
  /// count.
  private static func digest(_ key: [UInt32], _ mode: UInt32, _ data: [UInt8]) -> [UInt8] {
    let chunks = max(1, (data.count + 1023) / 1024)
    var stack = [[UInt32]]()
    for index in 0..<(chunks - 1) {
      var cv = chunk(key, mode, data, index, 0)
      var total = index + 1
      while total % 2 == 0 {
        cv = compress(key, stack.removeLast() + cv, 0, 64, mode | parent)
        total /= 2
      }
      stack.append(cv)
    }
    var final: [UInt32]
    if stack.isEmpty {
      final = chunk(key, mode, data, chunks - 1, root)
    } else {
      final = chunk(key, mode, data, chunks - 1, 0)
      while stack.count > 1 {
        final = compress(key, stack.removeLast() + final, 0, 64, mode | parent)
      }
      final = compress(key, stack[0] + final, 0, 64, mode | parent | root)
    }
    return final.flatMap { word in
      (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32(8 * $0)) }
    }
  }

  /// The 32-byte BLAKE3 hash of some bytes.
  public static func hash(_ data: [UInt8]) -> [UInt8] {
    digest(iv, 0, data)
  }

  /// The 32-byte BLAKE3 keyed hash of some bytes under a key of 32 bytes.
  public static func keyedHash(_ key: [UInt8], _ data: [UInt8]) throws -> [UInt8] {
    guard key.count == 32 else {
      throw Fail.with("InvalidKey", "blake3Keyed: the key is 32 bytes")
    }
    return digest(Array(words(key, 0, 32)[0..<8]), keyedHash, data)
  }

  /// The 32 bytes BLAKE3 derives from some key material in a context, which
  /// is a text.
  public static func deriveKey(_ context: String, _ material: [UInt8]) -> [UInt8] {
    let contextKey = digest(iv, deriveKeyContext, Array(context.utf8))
    return digest(Array(words(contextKey, 0, 32)[0..<8]), deriveKeyMaterial, material)
  }
}
