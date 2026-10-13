// ML-DSA-65 (FIPS 204) in pure Swift: the fallback for what CryptoKit keeps
// inside its keys. CryptoKit holds an ML-DSA key as its 32-byte seed, never
// exposes the expanded private key, and always hedges its signatures with
// fresh randomness. Known-answer tests need the expanded key and the
// deterministic signature, so this module provides key generation and
// signing; verification and hedged signing go through CryptoKit (see
// CryptoPrimitives).

/// FIPS 204's ML-DSA-65, the parts CryptoKit does not expose.
enum MLDSA65Fallback {
    static let q = 8_380_417
    static let d = 13
    static let tau = 49
    static let challengeBytes = 48
    static let gamma1 = 1 << 19
    static let gamma2 = (8_380_417 - 1) / 32
    static let k = 6
    static let l = 5
    static let eta = 4
    static let beta = 196
    static let omega = 55
    static let publicKeyLength = 1952
    static let privateKeyLength = 4032
    static let signatureLength = 3309

    typealias Polynomial = [Int]

    /// 1753^BitRev8(i) mod q, for the NTT.
    static let zetas: [Int] = (0..<256).map { power(1753, bitReverse8($0)) }

    private static func bitReverse8(_ value: Int) -> Int {
        var result = 0
        for bit in 0..<8 where value & (1 << bit) != 0 {
            result |= 1 << (7 - bit)
        }
        return result
    }

    private static func power(_ base: Int, _ exponent: Int) -> Int {
        var result = 1
        for _ in 0..<exponent {
            result = result * base % q
        }
        return result
    }

    private static func reduce(_ value: Int) -> Int {
        let r = value % q
        return r < 0 ? r + q : r
    }

    /// The representative of r mod alpha in (-alpha/2, alpha/2].
    private static func centered(_ r: Int, _ alpha: Int) -> Int {
        var r0 = r % alpha
        if r0 < 0 { r0 += alpha }
        if r0 > alpha / 2 { r0 -= alpha }
        return r0
    }

    private static func h(_ bytes: [UInt8], _ count: Int) -> [UInt8] { Keccak.shake256(bytes, count) }

    // MARK: NTT

    private static func ntt(_ input: Polynomial) -> Polynomial {
        var w = input
        var m = 0
        var length = 128
        while length >= 1 {
            var start = 0
            while start < 256 {
                m += 1
                let zeta = zetas[m]
                for j in start..<(start + length) {
                    let t = zeta * w[j + length] % q
                    w[j + length] = reduce(w[j] - t)
                    w[j] = (w[j] + t) % q
                }
                start += 2 * length
            }
            length /= 2
        }
        return w
    }

    private static func inverseNTT(_ input: Polynomial) -> Polynomial {
        var w = input
        var m = 256
        var length = 1
        while length < 256 {
            var start = 0
            while start < 256 {
                m -= 1
                let zeta = q - zetas[m]
                for j in start..<(start + length) {
                    let t = w[j]
                    w[j] = (t + w[j + length]) % q
                    w[j + length] = zeta * reduce(t - w[j + length]) % q
                }
                start += 2 * length
            }
            length *= 2
        }
        return w.map { $0 * 8_347_681 % q }
    }

    private static func multiply(_ f: Polynomial, _ g: Polynomial) -> Polynomial {
        (0..<256).map { f[$0] * g[$0] % q }
    }

    private static func add(_ f: Polynomial, _ g: Polynomial) -> Polynomial {
        (0..<256).map { (f[$0] + g[$0]) % q }
    }

    private static func subtract(_ f: Polynomial, _ g: Polynomial) -> Polynomial {
        (0..<256).map { reduce(f[$0] - g[$0]) }
    }

    // MARK: Sampling

    private static func rejectNTTPolynomial(_ seed: [UInt8]) -> Polynomial {
        var sponge = KeccakSponge.shake128()
        sponge.absorb(seed)
        var result = Polynomial(repeating: 0, count: 256)
        var count = 0
        while count < 256 {
            let bytes = sponge.squeeze(168)
            var index = 0
            while index + 3 <= bytes.count && count < 256 {
                let value = Int(bytes[index]) | Int(bytes[index + 1]) << 8 | (Int(bytes[index + 2]) & 0x7F) << 16
                if value < q {
                    result[count] = value
                    count += 1
                }
                index += 3
            }
        }
        return result
    }

    private static func rejectBoundedPolynomial(_ seed: [UInt8]) -> Polynomial {
        var sponge = KeccakSponge.shake256()
        sponge.absorb(seed)
        var result = Polynomial(repeating: 0, count: 256)
        var count = 0
        while count < 256 {
            for byte in sponge.squeeze(136) where count < 256 {
                let low = Int(byte & 0x0F)
                let high = Int(byte >> 4)
                if low < 9 {
                    result[count] = reduce(eta - low)
                    count += 1
                }
                if high < 9 && count < 256 {
                    result[count] = reduce(eta - high)
                    count += 1
                }
            }
        }
        return result
    }

    private static func expandA(_ rho: [UInt8]) -> [[Polynomial]] {
        (0..<k).map { r in (0..<l).map { s in rejectNTTPolynomial(rho + [UInt8(s), UInt8(r)]) } }
    }

    private static func twoBytes(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private static func expandMask(_ rho: [UInt8], _ offset: Int) -> [Polynomial] {
        (0..<l).map { r in
            let bytes = h(rho + twoBytes(offset + r), 32 * 20)
            return unpack(bytes[...], 20).map { reduce(gamma1 - $0) }
        }
    }

    private static func sampleInBall(_ seed: [UInt8]) -> Polynomial {
        var sponge = KeccakSponge.shake256()
        sponge.absorb(seed)
        let signs = sponge.squeeze(8)
        var c = Polynomial(repeating: 0, count: 256)
        var bit = 0
        for i in (256 - tau)..<256 {
            var j = Int(sponge.squeeze(1)[0])
            while j > i {
                j = Int(sponge.squeeze(1)[0])
            }
            c[i] = c[j]
            let negative = (signs[bit >> 3] >> UInt8(bit & 7)) & 1 == 1
            c[j] = negative ? q - 1 : 1
            bit += 1
        }
        return c
    }

    // MARK: Packing

    /// Values of a given bit width, packed little-endian.
    private static func pack(_ values: [Int], _ width: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: values.count * width / 8)
        var bitIndex = 0
        for value in values {
            for b in 0..<width {
                if (value >> b) & 1 == 1 {
                    out[bitIndex >> 3] |= UInt8(1) << UInt8(bitIndex & 7)
                }
                bitIndex += 1
            }
        }
        return out
    }

    private static func unpack(_ bytes: ArraySlice<UInt8>, _ width: Int) -> [Int] {
        let base = bytes.startIndex
        var result = [Int](repeating: 0, count: 256)
        var bitIndex = 0
        for i in 0..<256 {
            var value = 0
            for b in 0..<width {
                value |= (Int(bytes[base + (bitIndex >> 3)] >> UInt8(bitIndex & 7)) & 1) << b
                bitIndex += 1
            }
            result[i] = value
        }
        return result
    }

    /// BitPack(w, a, b): each b - w, in the width of a + b.
    private static func packBetween(_ f: Polynomial, _ upper: Int, _ width: Int) -> [UInt8] {
        pack(f.map { upper - centered($0, q) }, width)
    }

    private static func power2Round(_ r: Int) -> (high: Int, low: Int) {
        let low = centered(r, 1 << d)
        return ((r - low) >> d, low)
    }

    private static func decompose(_ r: Int) -> (high: Int, low: Int) {
        var low = centered(r, 2 * gamma2)
        if r - low == q - 1 {
            low -= 1
            return (0, low)
        }
        return ((r - low) / (2 * gamma2), low)
    }

    private static func infinityNorm(_ f: Polynomial) -> Int {
        f.reduce(0) { max($0, abs(centered($1, q))) }
    }

    // MARK: ML-DSA

    private struct Expanded {
        let rho: [UInt8]
        let key: [UInt8]
        let tr: [UInt8]
        let s1: [Polynomial]
        let s2: [Polynomial]
        let t0: [Polynomial]
        let publicKey: [UInt8]
    }

    private static func expand(_ seed: [UInt8]) -> Expanded {
        let expanded = h(seed + [UInt8(k), UInt8(l)], 128)
        let rho = Array(expanded[0..<32])
        let rhoPrime = Array(expanded[32..<96])
        let key = Array(expanded[96..<128])
        let a = expandA(rho)
        let s1 = (0..<l).map { rejectBoundedPolynomial(rhoPrime + twoBytes($0)) }
        let s2 = (0..<k).map { rejectBoundedPolynomial(rhoPrime + twoBytes($0 + l)) }
        let s1Hat = s1.map(ntt)
        var publicKey = rho
        var t0: [Polynomial] = []
        for i in 0..<k {
            var sum = Polynomial(repeating: 0, count: 256)
            for j in 0..<l {
                sum = add(sum, multiply(a[i][j], s1Hat[j]))
            }
            let t = add(inverseNTT(sum), s2[i])
            let rounded = t.map(power2Round)
            publicKey += pack(rounded.map { $0.high }, 10)
            t0.append(rounded.map { reduce($0.low) })
        }
        return Expanded(rho: rho, key: key, tr: h(publicKey, 64), s1: s1, s2: s2, t0: t0, publicKey: publicKey)
    }

    /// The public key and the expanded private key of a 32-byte seed.
    static func keyGen(_ seed: [UInt8]) -> (publicKey: [UInt8], privateKey: [UInt8]) {
        let e = expand(seed)
        var privateKey = e.rho + e.key + e.tr
        for s in e.s1 { privateKey += packBetween(s, eta, 4) }
        for s in e.s2 { privateKey += packBetween(s, eta, 4) }
        for t in e.t0 { privateKey += packBetween(t, 1 << (d - 1), 13) }
        return (e.publicKey, privateKey)
    }

    /// Sign with a context string. A deterministic signature uses 32 zero
    /// bytes as its randomness; a hedged one uses fresh bytes.
    static func sign(_ seed: [UInt8], _ message: [UInt8], _ context: [UInt8], randomness: [UInt8]) -> [UInt8] {
        let e = expand(seed)
        let a = expandA(e.rho)
        let s1Hat = e.s1.map(ntt)
        let s2Hat = e.s2.map(ntt)
        let t0Hat = e.t0.map(ntt)
        let prefixed = [0, UInt8(context.count)] + context + message
        let mu = h(e.tr + prefixed, 64)
        let rhoPrimePrime = h(e.key + randomness + mu, 64)
        var kappa = 0
        while true {
            let y = expandMask(rhoPrimePrime, kappa)
            kappa += l
            let yHat = y.map(ntt)
            var w: [Polynomial] = []
            for i in 0..<k {
                var sum = Polynomial(repeating: 0, count: 256)
                for j in 0..<l {
                    sum = add(sum, multiply(a[i][j], yHat[j]))
                }
                w.append(inverseNTT(sum))
            }
            var w1Encoded: [UInt8] = []
            for wi in w {
                w1Encoded += pack(wi.map { decompose($0).high }, 4)
            }
            let challenge = h(mu + w1Encoded, challengeBytes)
            let cHat = ntt(sampleInBall(challenge))
            let z = (0..<l).map { add(y[$0], inverseNTT(multiply(cHat, s1Hat[$0]))) }
            if z.contains(where: { infinityNorm($0) >= gamma1 - beta }) { continue }
            let r = (0..<k).map { subtract(w[$0], inverseNTT(multiply(cHat, s2Hat[$0]))) }
            if r.contains(where: { $0.contains { abs(decompose($0).low) >= gamma2 - beta } }) { continue }
            let ct0 = (0..<k).map { inverseNTT(multiply(cHat, t0Hat[$0])) }
            if ct0.contains(where: { infinityNorm($0) >= gamma2 }) { continue }
            var hints: [[Bool]] = []
            var ones = 0
            for i in 0..<k {
                var row: [Bool] = []
                let shifted = add(r[i], ct0[i])
                for j in 0..<256 {
                    let base = shifted[j]
                    let hint = decompose(base).high != decompose(reduce(base - ct0[i][j])).high
                    if hint { ones += 1 }
                    row.append(hint)
                }
                hints.append(row)
            }
            if ones > omega { continue }
            var signature = challenge
            for zi in z { signature += packBetween(zi, gamma1, 20) }
            var hintBytes = [UInt8](repeating: 0, count: omega + k)
            var index = 0
            for i in 0..<k {
                for j in 0..<256 where hints[i][j] {
                    hintBytes[index] = UInt8(j)
                    index += 1
                }
                hintBytes[omega + i] = UInt8(index)
            }
            return signature + hintBytes
        }
    }
}
