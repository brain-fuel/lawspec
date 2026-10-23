// NIST known-answer checks of the default crypto primitives, over the vectors
// every target shares (runtime/defaults/vectors.txt, provenance in
// docs/reference/language/cryptography.md). ref:DEC-tests-cite-requirements

import LawSpecRuntime

/// The known-answer checks of lawspec.crypto's primitives.
public enum CryptoVectors {
  private static func fail(_ kind: String, _ detail: String) -> CryptoFailure {
    CryptoFailure(code: "CryptoVectorFailed", detail: kind + ": " + detail)
  }

  private static func hex(_ text: Substring) -> [UInt8] {
    if text == "-" { return [] }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(text.count / 2)
    var index = text.startIndex
    while index < text.endIndex {
      let next = text.index(index, offsetBy: 2)
      bytes.append(UInt8(text[index..<next], radix: 16) ?? 0)
      index = next
    }
    return bytes
  }

  private static func hexText(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef")
    return String(bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] })
  }

  private static func digest(_ bytes: [UInt8]) -> String { hexText(CryptoPrimitives.sha3(bytes)) }

  private static func flip(_ bytes: [UInt8]) -> [UInt8] {
    var copy = bytes
    copy[0] ^= 1
    return copy
  }

  private static func same(_ kind: String, _ what: String, _ expected: [UInt8], _ actual: [UInt8])
    throws(CryptoFailure)
  {
    if expected != actual { throw fail(kind, what + " differs") }
  }

  private static func holds(_ kind: String, _ what: String, _ condition: Bool) throws(CryptoFailure)
  {
    if !condition { throw fail(kind, what) }
  }

  /// Check every vector of a kind in the vectors text.
  public static func check(_ vectors: String, _ kind: String) throws(CryptoFailure) {
    let rows = vectors.split(separator: "\n")
      .map { $0.split(separator: " ", omittingEmptySubsequences: true) }
      .filter { !$0.isEmpty && $0[0] == kind }
      .map { Array($0.dropFirst()) }
    if rows.isEmpty { throw fail(kind, "no vectors") }
    for row in rows {
      switch (kind, row.count) {
      case ("sha3-256", 2):
        try same(kind, "digest", hex(row[1]), CryptoPrimitives.sha3(hex(row[0])))
      case ("shake256", 3):
        try same(kind, "output", hex(row[2]), CryptoPrimitives.shake(hex(row[0]), Int(row[1]) ?? 0))
      case ("aes-256-gcm", 6):
        let key = hex(row[0])
        let nonce = hex(row[1])
        let message = hex(row[2])
        let associated = hex(row[3])
        let expected = hex(row[4]) + hex(row[5])
        try same(
          kind, "sealed", expected,
          try CryptoPrimitives.aes256GcmEncrypt(key, nonce, message, associated))
        try holds(
          kind, "decrypts",
          CryptoPrimitives.aes256GcmDecrypt(key, nonce, expected, associated) == message)
        try holds(
          kind, "rejects a changed ciphertext",
          CryptoPrimitives.aes256GcmDecrypt(key, nonce, flip(expected), associated) == nil)
      case ("mlkem768-keygen", 4):
        let seed = hex(row[0]) + hex(row[1])
        let (publicKey, privateKey) = CryptoPrimitives.mlkemExpand(seed)
        try holds(kind, "public key", digest(publicKey) == String(row[2]))
        try holds(kind, "private key", digest(privateKey) == String(row[3]))
        let pair = CryptoPrimitives.mlkemKeyPair(seed)
        try holds(kind, "key pair", pair.publicKey == publicKey && pair.seed == seed)
      case ("mlkem768-encaps", 4):
        let (ciphertext, shared) = try CryptoPrimitives.mlkemEncapsulateWith(
          hex(row[0]), hex(row[1]))
        try same(kind, "ciphertext", hex(row[2]), ciphertext)
        try same(kind, "shared secret", hex(row[3]), shared)
      case ("mlkem768-decaps", 3):
        try same(
          kind, "shared secret", hex(row[2]),
          try CryptoPrimitives.mlkemDecapsulateExpanded(hex(row[0]), hex(row[1])))
      case ("mlkem768-decaps-seed", 3):
        try same(
          kind, "shared secret", hex(row[2]),
          try CryptoPrimitives.mlkemDecapsulate(hex(row[0]), hex(row[1])))
      case ("mldsa65-keygen", 3):
        let seed = hex(row[0])
        let (publicKey, privateKey) = CryptoPrimitives.mldsaExpand(seed)
        try holds(kind, "public key", digest(publicKey) == String(row[1]))
        try holds(kind, "private key", digest(privateKey) == String(row[2]))
        try same(kind, "public key of the seed", publicKey, CryptoPrimitives.mldsaPublic(seed))
      case ("mldsa65-verify", 5):
        let verified = CryptoPrimitives.mldsaVerifyWith(
          hex(row[0]), hex(row[1]), hex(row[3]), hex(row[2]))
        try holds(kind, "verification", verified == (row[4] == "true"))
      case ("mldsa65-sign-seed", 3):
        let seed = hex(row[0])
        let message = hex(row[1])
        let signed = try CryptoPrimitives.mldsaSignWith(seed, message, [], deterministic: true)
        try same(kind, "signature", hex(row[2]), signed)
        let publicKey = CryptoPrimitives.mldsaPublic(seed)
        try holds(kind, "verifies", CryptoPrimitives.mldsaVerify(publicKey, message, signed))
        try holds(
          kind, "rejects a changed message",
          !CryptoPrimitives.mldsaVerify(publicKey, flip(message), signed))
      case ("slhdsa128f-keygen", 5):
        let (publicKey, privateKey) = CryptoPrimitives.slhKeyPairOf(
          hex(row[0]) + hex(row[1]) + hex(row[2]))
        try same(kind, "public key", hex(row[3]), publicKey)
        try holds(kind, "private key", digest(privateKey) == String(row[4]))
        let message = Array("LawSpec".utf8)
        let signature = try CryptoPrimitives.slhSign(privateKey, message)
        try holds(kind, "verifies", CryptoPrimitives.slhVerify(publicKey, message, signature))
        try holds(
          kind, "rejects a changed message",
          !CryptoPrimitives.slhVerify(publicKey, Array("LawSpeC".utf8), signature))
      case ("slhdsa128f-verify", 5):
        let publicKey = hex(row[0])
        let message = hex(row[1])
        let context = hex(row[2])
        let signature = hex(row[3])
        try holds(
          kind, "verification",
          CryptoPrimitives.slhVerifyWith(publicKey, message, signature, context)
            == (row[4] == "true"))
        try holds(
          kind, "rejects a changed message",
          !CryptoPrimitives.slhVerifyWith(publicKey, flip(message), signature, context))
      default:
        throw fail(kind, "unexpected row of \(row.count) fields")
      }
    }
  }
}
