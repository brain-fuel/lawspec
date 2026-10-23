// SLH-DSA-SHAKE-128f (FIPS 205) in pure Swift. CryptoKit has no stateless
// hash-based signatures, so this whole module is a fallback: key generation
// from the three seeds, hedged or deterministic signing with a context, and
// verification.

/// FIPS 205's SLH-DSA-SHAKE-128f.
enum SLHDSAShake128f {
  static let n = 16
  static let fullHeight = 66
  static let layers = 22
  static let treeHeight = 3
  static let forsHeight = 6
  static let forsTrees = 33
  static let w = 16
  static let len1 = 32
  static let len2 = 3
  static let len = 35
  static let messageDigestLength = 34
  static let publicKeyLength = 32
  static let privateKeyLength = 64
  static let signatureLength = 17088

  /// A hash address: 32 bytes of layer, tree, type and position fields.
  private struct Address {
    var bytes = [UInt8](repeating: 0, count: 32)

    static let wotsHash: UInt32 = 0
    static let wotsPublicKey: UInt32 = 1
    static let tree: UInt32 = 2
    static let forsTree: UInt32 = 3
    static let forsRoots: UInt32 = 4
    static let wotsPRF: UInt32 = 5
    static let forsPRF: UInt32 = 6

    private mutating func setWord(_ offset: Int, _ value: UInt32) {
      bytes[offset] = UInt8(truncatingIfNeeded: value >> 24)
      bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
      bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
      bytes[offset + 3] = UInt8(truncatingIfNeeded: value)
    }

    private func word(_ offset: Int) -> UInt32 {
      UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8
        | UInt32(bytes[offset + 3])
    }

    mutating func setLayer(_ layer: Int) { setWord(0, UInt32(layer)) }

    mutating func setTree(_ tree: UInt64) {
      for i in 4..<8 { bytes[i] = 0 }
      for i in 0..<8 { bytes[8 + i] = UInt8(truncatingIfNeeded: tree >> UInt64(8 * (7 - i))) }
    }

    mutating func setTypeAndClear(_ type: UInt32) {
      setWord(16, type)
      for i in 20..<32 { bytes[i] = 0 }
    }

    mutating func setKeyPair(_ value: Int) { setWord(20, UInt32(value)) }
    var keyPair: Int { Int(word(20)) }
    mutating func setChain(_ value: Int) { setWord(24, UInt32(value)) }
    mutating func setTreeHeight(_ value: Int) { setWord(24, UInt32(value)) }
    mutating func setHash(_ value: Int) { setWord(28, UInt32(value)) }
    mutating func setTreeIndex(_ value: Int) { setWord(28, UInt32(value)) }
    var treeIndex: Int { Int(word(28)) }
  }

  /// The tweakable hash F, H and T: SHAKE256 of the public seed, the
  /// address and the message.
  private static func tweak(_ seed: [UInt8], _ address: Address, _ message: [UInt8]) -> [UInt8] {
    var sponge = KeccakSponge.shake256()
    sponge.absorb(seed)
    sponge.absorb(address.bytes)
    sponge.absorb(message)
    return sponge.squeeze(n)
  }

  private static func prf(_ publicSeed: [UInt8], _ secretSeed: [UInt8], _ address: Address)
    -> [UInt8]
  {
    var sponge = KeccakSponge.shake256()
    sponge.absorb(publicSeed)
    sponge.absorb(address.bytes)
    sponge.absorb(secretSeed)
    return sponge.squeeze(n)
  }

  private static func baseTwoB(_ x: [UInt8], _ b: Int, _ count: Int) -> [Int] {
    var input = 0
    var bits = 0
    var total = 0
    var out: [Int] = []
    out.reserveCapacity(count)
    for _ in 0..<count {
      while bits < b {
        total = (total << 8) | Int(x[input])
        input += 1
        bits += 8
      }
      bits -= b
      out.append((total >> bits) & ((1 << b) - 1))
      total &= (1 << bits) - 1
    }
    return out
  }

  // MARK: WOTS+

  private static func chain(
    _ x: [UInt8], _ start: Int, _ steps: Int, _ seed: [UInt8], _ address: inout Address
  ) -> [UInt8] {
    var value = x
    for j in start..<(start + steps) {
      address.setHash(j)
      value = tweak(seed, address, value)
    }
    return value
  }

  private static func wotsDigits(_ message: [UInt8]) -> [Int] {
    var digits = baseTwoB(message, 4, len1)
    var checksum = digits.reduce(0) { $0 + (w - 1 - $1) }
    checksum <<= 4
    digits += baseTwoB(
      [UInt8(truncatingIfNeeded: checksum >> 8), UInt8(truncatingIfNeeded: checksum)], 4, len2)
    return digits
  }

  private static func wotsSecret(
    _ secretSeed: [UInt8], _ publicSeed: [UInt8], _ address: Address, _ chainIndex: Int
  ) -> [UInt8] {
    var secretAddress = address
    secretAddress.setTypeAndClear(Address.wotsPRF)
    secretAddress.setKeyPair(address.keyPair)
    secretAddress.setChain(chainIndex)
    return prf(publicSeed, secretSeed, secretAddress)
  }

  private static func wotsCompress(_ parts: [UInt8], _ seed: [UInt8], _ address: Address) -> [UInt8]
  {
    var publicAddress = address
    publicAddress.setTypeAndClear(Address.wotsPublicKey)
    publicAddress.setKeyPair(address.keyPair)
    return tweak(seed, publicAddress, parts)
  }

  private static func wotsPublicKey(
    _ secretSeed: [UInt8], _ publicSeed: [UInt8], _ address: inout Address
  ) -> [UInt8] {
    var parts: [UInt8] = []
    for i in 0..<len {
      let secret = wotsSecret(secretSeed, publicSeed, address, i)
      address.setChain(i)
      parts += chain(secret, 0, w - 1, publicSeed, &address)
    }
    return wotsCompress(parts, publicSeed, address)
  }

  private static func wotsSign(
    _ message: [UInt8], _ secretSeed: [UInt8], _ publicSeed: [UInt8], _ address: inout Address
  ) -> [UInt8] {
    var signature: [UInt8] = []
    for (i, digit) in wotsDigits(message).enumerated() {
      let secret = wotsSecret(secretSeed, publicSeed, address, i)
      address.setChain(i)
      signature += chain(secret, 0, digit, publicSeed, &address)
    }
    return signature
  }

  private static func wotsPublicKeyFromSignature(
    _ signature: ArraySlice<UInt8>, _ message: [UInt8], _ seed: [UInt8], _ address: inout Address
  ) -> [UInt8] {
    let base = signature.startIndex
    var parts: [UInt8] = []
    for (i, digit) in wotsDigits(message).enumerated() {
      address.setChain(i)
      parts += chain(
        Array(signature[(base + i * n)..<(base + i * n + n)]), digit, w - 1 - digit, seed, &address)
    }
    return wotsCompress(parts, seed, address)
  }

  // MARK: XMSS and the hypertree

  private static func xmssNode(
    _ secretSeed: [UInt8], _ index: Int, _ height: Int, _ publicSeed: [UInt8],
    _ address: inout Address
  ) -> [UInt8] {
    if height == 0 {
      address.setTypeAndClear(Address.wotsHash)
      address.setKeyPair(index)
      return wotsPublicKey(secretSeed, publicSeed, &address)
    }
    let left = xmssNode(secretSeed, 2 * index, height - 1, publicSeed, &address)
    let right = xmssNode(secretSeed, 2 * index + 1, height - 1, publicSeed, &address)
    address.setTypeAndClear(Address.tree)
    address.setTreeHeight(height)
    address.setTreeIndex(index)
    return tweak(publicSeed, address, left + right)
  }

  private static func xmssSign(
    _ message: [UInt8], _ secretSeed: [UInt8], _ index: Int, _ publicSeed: [UInt8],
    _ address: inout Address
  ) -> [UInt8] {
    var authentication: [UInt8] = []
    for j in 0..<treeHeight {
      authentication += xmssNode(secretSeed, (index >> j) ^ 1, j, publicSeed, &address)
    }
    address.setTypeAndClear(Address.wotsHash)
    address.setKeyPair(index)
    return wotsSign(message, secretSeed, publicSeed, &address) + authentication
  }

  private static func xmssRoot(
    _ index: Int, _ signature: ArraySlice<UInt8>, _ message: [UInt8], _ seed: [UInt8],
    _ address: inout Address
  ) -> [UInt8] {
    let base = signature.startIndex
    address.setTypeAndClear(Address.wotsHash)
    address.setKeyPair(index)
    var node = wotsPublicKeyFromSignature(
      signature[base..<(base + len * n)], message, seed, &address)
    address.setTypeAndClear(Address.tree)
    address.setTreeIndex(index)
    for k in 0..<treeHeight {
      let start = base + len * n + k * n
      let sibling = Array(signature[start..<(start + n)])
      address.setTreeHeight(k + 1)
      if (index >> k) & 1 == 0 {
        address.setTreeIndex(address.treeIndex / 2)
        node = tweak(seed, address, node + sibling)
      } else {
        address.setTreeIndex((address.treeIndex - 1) / 2)
        node = tweak(seed, address, sibling + node)
      }
    }
    return node
  }

  private static let xmssSignatureLength = (len + treeHeight) * n

  private static func hypertreeSign(
    _ message: [UInt8], _ secretSeed: [UInt8], _ publicSeed: [UInt8], _ tree: UInt64, _ leaf: Int
  ) -> [UInt8] {
    var address = Address()
    var treeIndex = tree
    var leafIndex = leaf
    address.setTree(treeIndex)
    var part = xmssSign(message, secretSeed, leafIndex, publicSeed, &address)
    var signature = part
    var root = xmssRoot(leafIndex, part[...], message, publicSeed, &address)
    for j in 1..<layers {
      leafIndex = Int(treeIndex & UInt64((1 << treeHeight) - 1))
      treeIndex >>= UInt64(treeHeight)
      address.setLayer(j)
      address.setTree(treeIndex)
      part = xmssSign(root, secretSeed, leafIndex, publicSeed, &address)
      signature += part
      if j < layers - 1 {
        root = xmssRoot(leafIndex, part[...], root, publicSeed, &address)
      }
    }
    return signature
  }

  private static func hypertreeVerify(
    _ message: [UInt8], _ signature: ArraySlice<UInt8>, _ seed: [UInt8], _ tree: UInt64,
    _ leaf: Int, _ root: [UInt8]
  ) -> Bool {
    let base = signature.startIndex
    var address = Address()
    var treeIndex = tree
    var leafIndex = leaf
    address.setTree(treeIndex)
    var node = xmssRoot(
      leafIndex, signature[base..<(base + xmssSignatureLength)], message, seed, &address)
    for j in 1..<layers {
      leafIndex = Int(treeIndex & UInt64((1 << treeHeight) - 1))
      treeIndex >>= UInt64(treeHeight)
      address.setLayer(j)
      address.setTree(treeIndex)
      let start = base + j * xmssSignatureLength
      node = xmssRoot(
        leafIndex, signature[start..<(start + xmssSignatureLength)], node, seed, &address)
    }
    return node == root
  }

  // MARK: FORS

  private static func forsSecret(
    _ secretSeed: [UInt8], _ publicSeed: [UInt8], _ address: Address, _ index: Int
  ) -> [UInt8] {
    var secretAddress = address
    secretAddress.setTypeAndClear(Address.forsPRF)
    secretAddress.setKeyPair(address.keyPair)
    secretAddress.setTreeIndex(index)
    return prf(publicSeed, secretSeed, secretAddress)
  }

  private static func forsNode(
    _ secretSeed: [UInt8], _ index: Int, _ height: Int, _ publicSeed: [UInt8],
    _ address: inout Address
  ) -> [UInt8] {
    if height == 0 {
      let secret = forsSecret(secretSeed, publicSeed, address, index)
      address.setTreeHeight(0)
      address.setTreeIndex(index)
      return tweak(publicSeed, address, secret)
    }
    let left = forsNode(secretSeed, 2 * index, height - 1, publicSeed, &address)
    let right = forsNode(secretSeed, 2 * index + 1, height - 1, publicSeed, &address)
    address.setTreeHeight(height)
    address.setTreeIndex(index)
    return tweak(publicSeed, address, left + right)
  }

  private static func forsSign(
    _ digest: [UInt8], _ secretSeed: [UInt8], _ publicSeed: [UInt8], _ address: inout Address
  ) -> [UInt8] {
    var signature: [UInt8] = []
    for (i, index) in baseTwoB(digest, forsHeight, forsTrees).enumerated() {
      signature += forsSecret(secretSeed, publicSeed, address, (i << forsHeight) + index)
      for j in 0..<forsHeight {
        let sibling = (index >> j) ^ 1
        signature += forsNode(
          secretSeed, (i << (forsHeight - j)) + sibling, j, publicSeed, &address)
      }
    }
    return signature
  }

  private static func forsPublicKey(
    _ signature: ArraySlice<UInt8>, _ digest: [UInt8], _ seed: [UInt8], _ address: inout Address
  ) -> [UInt8] {
    let base = signature.startIndex
    var roots: [UInt8] = []
    for (i, index) in baseTwoB(digest, forsHeight, forsTrees).enumerated() {
      let start = base + i * (forsHeight + 1) * n
      address.setTreeHeight(0)
      address.setTreeIndex((i << forsHeight) + index)
      var node = tweak(seed, address, Array(signature[start..<(start + n)]))
      for j in 0..<forsHeight {
        let siblingStart = start + (j + 1) * n
        let sibling = Array(signature[siblingStart..<(siblingStart + n)])
        address.setTreeHeight(j + 1)
        if (index >> j) & 1 == 0 {
          address.setTreeIndex(address.treeIndex / 2)
          node = tweak(seed, address, node + sibling)
        } else {
          address.setTreeIndex((address.treeIndex - 1) / 2)
          node = tweak(seed, address, sibling + node)
        }
      }
      roots += node
    }
    var rootsAddress = address
    rootsAddress.setTypeAndClear(Address.forsRoots)
    rootsAddress.setKeyPair(address.keyPair)
    return tweak(seed, rootsAddress, roots)
  }

  private static let forsSignatureLength = forsTrees * (forsHeight + 1) * n

  // MARK: SLH-DSA

  /// The key pair of SK.seed || SK.prf || PK.seed: the 32-byte public key
  /// and the 64-byte private key.
  static func keyGen(_ seed: [UInt8]) -> (publicKey: [UInt8], privateKey: [UInt8]) {
    let secretSeed = Array(seed[0..<n])
    let publicSeed = Array(seed[(2 * n)..<(3 * n)])
    var address = Address()
    address.setLayer(layers - 1)
    let root = xmssNode(secretSeed, 0, treeHeight, publicSeed, &address)
    return (publicSeed + root, seed + root)
  }

  /// The message digest's FORS part, tree index and leaf index.
  private static func split(_ digest: [UInt8]) -> (fors: [UInt8], tree: UInt64, leaf: Int) {
    let fors = Array(digest[0..<25])
    var tree: UInt64 = 0
    for byte in digest[25..<33] { tree = tree << 8 | UInt64(byte) }
    tree &= (UInt64(1) << 63) - 1
    let leaf = Int(digest[33]) & ((1 << treeHeight) - 1)
    return (fors, tree, leaf)
  }

  private static func messageDigest(
    _ randomizer: [UInt8], _ publicKey: ArraySlice<UInt8>, _ message: [UInt8]
  ) -> [UInt8] {
    var sponge = KeccakSponge.shake256()
    sponge.absorb(randomizer)
    sponge.absorb(Array(publicKey))
    sponge.absorb(message)
    return sponge.squeeze(messageDigestLength)
  }

  /// Sign with a context string; the additional randomness is n fresh bytes
  /// for a hedged signature, or the public seed for a deterministic one.
  static func sign(
    _ privateKey: [UInt8], _ message: [UInt8], _ context: [UInt8], additionalRandomness: [UInt8]
  ) -> [UInt8] {
    let secretSeed = Array(privateKey[0..<n])
    let secretPRF = Array(privateKey[n..<(2 * n)])
    let publicSeed = Array(privateKey[(2 * n)..<(3 * n)])
    let prefixed = [0, UInt8(context.count)] + context + message
    var sponge = KeccakSponge.shake256()
    sponge.absorb(secretPRF)
    sponge.absorb(additionalRandomness)
    sponge.absorb(prefixed)
    let randomizer = sponge.squeeze(n)
    let (fors, tree, leaf) = split(
      messageDigest(randomizer, privateKey[(2 * n)..<(4 * n)], prefixed))
    var address = Address()
    address.setTree(tree)
    address.setTypeAndClear(Address.forsTree)
    address.setKeyPair(leaf)
    let forsSignature = forsSign(fors, secretSeed, publicSeed, &address)
    let forsKey = forsPublicKey(forsSignature[...], fors, publicSeed, &address)
    return randomizer + forsSignature + hypertreeSign(forsKey, secretSeed, publicSeed, tree, leaf)
  }

  /// Verify a signature with a context string.
  static func verify(
    _ publicKey: [UInt8], _ message: [UInt8], _ signature: [UInt8], _ context: [UInt8]
  ) -> Bool {
    guard publicKey.count == publicKeyLength, signature.count == signatureLength,
      context.count <= 255
    else { return false }
    let publicSeed = Array(publicKey[0..<n])
    let root = Array(publicKey[n..<(2 * n)])
    let prefixed = [0, UInt8(context.count)] + context + message
    let randomizer = Array(signature[0..<n])
    let (fors, tree, leaf) = split(messageDigest(randomizer, publicKey[...], prefixed))
    var address = Address()
    address.setTree(tree)
    address.setTypeAndClear(Address.forsTree)
    address.setKeyPair(leaf)
    let forsKey = forsPublicKey(
      signature[n..<(n + forsSignatureLength)], fors, publicSeed, &address)
    return hypertreeVerify(
      forsKey, signature[(n + forsSignatureLength)...], publicSeed, tree, leaf, root)
  }
}
