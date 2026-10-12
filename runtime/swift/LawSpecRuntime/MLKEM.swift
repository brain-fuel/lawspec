// ML-KEM-768 (FIPS 203) in pure Swift: the fallback for what CryptoKit
// keeps inside its keys. CryptoKit holds an ML-KEM key as its 64-byte seed and
// never exposes the expanded decapsulation key, cannot decapsulate with one,
// and always draws an encapsulation's message at random. Known-answer tests
// need all three, so this module provides them; everything else goes through
// CryptoKit (see CryptoPrimitives).

/// FIPS 203's ML-KEM-768, the parts CryptoKit does not expose.
enum MLKEM768Fallback {
    static let q = 3329
    static let k = 3
    static let eta1 = 2
    static let eta2 = 2
    static let du = 10
    static let dv = 4
    static let publicKeyLength = 384 * 3 + 32
    static let privateKeyLength = 768 * 3 + 96
    static let ciphertextLength = 32 * (10 * 3 + 4)

    typealias Polynomial = [Int]

    /// zeta^BitRev7(i) mod q, for the NTT.
    static let zetas: [Int] = (0..<128).map { power(17, bitReverse7($0)) }
    /// zeta^(2 BitRev7(i) + 1) mod q, for multiplication in the NTT domain.
    static let gammas: [Int] = (0..<128).map { power(17, 2 * bitReverse7($0) + 1) }

    private static func bitReverse7(_ value: Int) -> Int {
        var result = 0
        for bit in 0..<7 where value & (1 << bit) != 0 {
            result |= 1 << (6 - bit)
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

    // MARK: Hashes

    private static func h(_ bytes: [UInt8]) -> [UInt8] { Keccak.sha3_256(bytes) }
    private static func g(_ bytes: [UInt8]) -> ([UInt8], [UInt8]) {
        let digest = Keccak.sha3_512(bytes)
        return (Array(digest[0..<32]), Array(digest[32..<64]))
    }
    private static func prf(_ eta: Int, _ seed: [UInt8], _ nonce: UInt8) -> [UInt8] {
        Keccak.shake256(seed + [nonce], 64 * eta)
    }

    // MARK: Sampling

    /// A uniform polynomial in the NTT domain from a seed and two indices.
    private static func sampleNTT(_ rho: [UInt8], _ j: UInt8, _ i: UInt8) -> Polynomial {
        var sponge = KeccakSponge.shake128()
        sponge.absorb(rho + [j, i])
        var result = Polynomial(repeating: 0, count: 256)
        var count = 0
        while count < 256 {
            let c = sponge.squeeze(168)
            var index = 0
            while index + 3 <= c.count && count < 256 {
                let d1 = Int(c[index]) + 256 * (Int(c[index + 1]) & 0x0F)
                let d2 = (Int(c[index + 1]) >> 4) + 16 * Int(c[index + 2])
                if d1 < q {
                    result[count] = d1
                    count += 1
                }
                if d2 < q && count < 256 {
                    result[count] = d2
                    count += 1
                }
                index += 3
            }
        }
        return result
    }

    /// A centered binomial polynomial from 64 eta bytes.
    private static func sampleCBD(_ eta: Int, _ bytes: [UInt8]) -> Polynomial {
        var result = Polynomial(repeating: 0, count: 256)
        func bit(_ index: Int) -> Int { Int(bytes[index >> 3] >> UInt8(index & 7)) & 1 }
        for i in 0..<256 {
            var x = 0
            var y = 0
            for j in 0..<eta {
                x += bit(2 * i * eta + j)
                y += bit(2 * i * eta + eta + j)
            }
            result[i] = reduce(x - y)
        }
        return result
    }

    // MARK: NTT

    private static func ntt(_ input: Polynomial) -> Polynomial {
        var f = input
        var index = 1
        var length = 128
        while length >= 2 {
            var start = 0
            while start < 256 {
                let zeta = zetas[index]
                index += 1
                for j in start..<(start + length) {
                    let t = zeta * f[j + length] % q
                    f[j + length] = reduce(f[j] - t)
                    f[j] = (f[j] + t) % q
                }
                start += 2 * length
            }
            length /= 2
        }
        return f
    }

    private static func inverseNTT(_ input: Polynomial) -> Polynomial {
        var f = input
        var index = 127
        var length = 2
        while length <= 128 {
            var start = 0
            while start < 256 {
                let zeta = zetas[index]
                index -= 1
                for j in start..<(start + length) {
                    let t = f[j]
                    f[j] = (t + f[j + length]) % q
                    f[j + length] = zeta * reduce(f[j + length] - t) % q
                }
                start += 2 * length
            }
            length *= 2
        }
        return f.map { $0 * 3303 % q }
    }

    private static func multiplyNTT(_ f: Polynomial, _ g: Polynomial) -> Polynomial {
        var result = Polynomial(repeating: 0, count: 256)
        for i in 0..<128 {
            let a0 = f[2 * i], a1 = f[2 * i + 1], b0 = g[2 * i], b1 = g[2 * i + 1]
            result[2 * i] = (a0 * b0 + (a1 * b1 % q) * gammas[i]) % q
            result[2 * i + 1] = (a0 * b1 + a1 * b0) % q
        }
        return result
    }

    private static func add(_ f: Polynomial, _ g: Polynomial) -> Polynomial {
        (0..<256).map { (f[$0] + g[$0]) % q }
    }

    // MARK: Encoding

    private static func encode(_ d: Int, _ f: Polynomial) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32 * d)
        var bitIndex = 0
        for value in f {
            for b in 0..<d {
                if (value >> b) & 1 == 1 {
                    out[bitIndex >> 3] |= UInt8(1) << UInt8(bitIndex & 7)
                }
                bitIndex += 1
            }
        }
        return out
    }

    private static func decode(_ d: Int, _ bytes: ArraySlice<UInt8>) -> Polynomial {
        let base = bytes.startIndex
        var result = Polynomial(repeating: 0, count: 256)
        var bitIndex = 0
        for i in 0..<256 {
            var value = 0
            for b in 0..<d {
                let bit = Int(bytes[base + (bitIndex >> 3)] >> UInt8(bitIndex & 7)) & 1
                value |= bit << b
                bitIndex += 1
            }
            result[i] = d == 12 ? value % q : value
        }
        return result
    }

    private static func compress(_ d: Int, _ f: Polynomial) -> Polynomial {
        // round(2^d x / q) mod 2^d, in integers.
        f.map { (((($0 << d) * 2) + q) / (2 * q)) & ((1 << d) - 1) }
    }

    private static func decompress(_ d: Int, _ f: Polynomial) -> Polynomial {
        // round(q y / 2^d), in integers.
        f.map { ($0 * q * 2 + (1 << d)) >> (d + 1) }
    }

    // MARK: K-PKE

    private static func matrix(_ rho: [UInt8]) -> [[Polynomial]] {
        (0..<k).map { i in (0..<k).map { j in sampleNTT(rho, UInt8(j), UInt8(i)) } }
    }

    private static func pkeKeyGen(_ d: [UInt8]) -> (ek: [UInt8], dk: [UInt8]) {
        let (rho, sigma) = g(d + [UInt8(k)])
        let a = matrix(rho)
        var nonce: UInt8 = 0
        var s: [Polynomial] = []
        var e: [Polynomial] = []
        for _ in 0..<k {
            s.append(ntt(sampleCBD(eta1, prf(eta1, sigma, nonce))))
            nonce += 1
        }
        for _ in 0..<k {
            e.append(ntt(sampleCBD(eta1, prf(eta1, sigma, nonce))))
            nonce += 1
        }
        var ek: [UInt8] = []
        var dk: [UInt8] = []
        for i in 0..<k {
            var t = e[i]
            for j in 0..<k {
                t = add(t, multiplyNTT(a[i][j], s[j]))
            }
            ek += encode(12, t)
            dk += encode(12, s[i])
        }
        return (ek + rho, dk)
    }

    private static func pkeEncrypt(_ ek: [UInt8], _ message: [UInt8], _ randomness: [UInt8]) -> [UInt8] {
        let t = (0..<k).map { decode(12, ek[(384 * $0)..<(384 * $0 + 384)]) }
        let rho = Array(ek[(384 * k)...])
        let a = matrix(rho)
        var nonce: UInt8 = 0
        var y: [Polynomial] = []
        for _ in 0..<k {
            y.append(ntt(sampleCBD(eta1, prf(eta1, randomness, nonce))))
            nonce += 1
        }
        var e1: [Polynomial] = []
        for _ in 0..<k {
            e1.append(sampleCBD(eta2, prf(eta2, randomness, nonce)))
            nonce += 1
        }
        let e2 = sampleCBD(eta2, prf(eta2, randomness, nonce))
        var c1: [UInt8] = []
        for i in 0..<k {
            var sum = Polynomial(repeating: 0, count: 256)
            for j in 0..<k {
                sum = add(sum, multiplyNTT(a[j][i], y[j]))
            }
            c1 += encode(du, compress(du, add(inverseNTT(sum), e1[i])))
        }
        var sum = Polynomial(repeating: 0, count: 256)
        for j in 0..<k {
            sum = add(sum, multiplyNTT(t[j], y[j]))
        }
        let mu = decompress(1, decode(1, message[...]))
        let v = add(add(inverseNTT(sum), e2), mu)
        return c1 + encode(dv, compress(dv, v))
    }

    private static func pkeDecrypt(_ dk: ArraySlice<UInt8>, _ ciphertext: [UInt8]) -> [UInt8] {
        let base = dk.startIndex
        let u = (0..<k).map { decompress(du, decode(du, ciphertext[(32 * du * $0)..<(32 * du * ($0 + 1))])) }
        let v = decompress(dv, decode(dv, ciphertext[(32 * du * k)...]))
        let s = (0..<k).map { decode(12, dk[(base + 384 * $0)..<(base + 384 * $0 + 384)]) }
        var sum = Polynomial(repeating: 0, count: 256)
        for i in 0..<k {
            sum = add(sum, multiplyNTT(s[i], ntt(u[i])))
        }
        let product = inverseNTT(sum)
        let w = (0..<256).map { reduce(v[$0] - product[$0]) }
        return encode(1, compress(1, w))
    }

    // MARK: ML-KEM

    /// The encapsulation key and the expanded decapsulation key of d || z.
    static func keyGen(_ seed: [UInt8]) -> (publicKey: [UInt8], privateKey: [UInt8]) {
        let d = Array(seed[0..<32])
        let z = Array(seed[32..<64])
        let (ek, dkPke) = pkeKeyGen(d)
        return (ek, dkPke + ek + h(ek) + z)
    }

    /// Whether an encapsulation key passes FIPS 203's modulus check.
    static func validPublicKey(_ ek: [UInt8]) -> Bool {
        guard ek.count == publicKeyLength else { return false }
        for i in 0..<k {
            let slice = ek[(384 * i)..<(384 * i + 384)]
            if encode(12, decode(12, slice)) != Array(slice) { return false }
        }
        return true
    }

    /// Deterministic encapsulation with the 32-byte message m.
    static func encapsulate(_ ek: [UInt8], _ message: [UInt8]) -> (ciphertext: [UInt8], shared: [UInt8]) {
        let (shared, randomness) = g(message + h(ek))
        return (pkeEncrypt(ek, message, randomness), shared)
    }

    /// Decapsulation with an expanded decapsulation key, rejecting implicitly.
    static func decapsulate(_ dk: [UInt8], _ ciphertext: [UInt8]) -> [UInt8] {
        let dkPke = dk[0..<(384 * k)]
        let ek = Array(dk[(384 * k)..<(768 * k + 32)])
        let hash = Array(dk[(768 * k + 32)..<(768 * k + 64)])
        let z = Array(dk[(768 * k + 64)..<(768 * k + 96)])
        let message = pkeDecrypt(dkPke, ciphertext)
        let (shared, randomness) = g(message + hash)
        let rejected = Keccak.shake256(z + ciphertext, 32)
        let again = pkeEncrypt(ek, message, randomness)
        // Constant-time selection of the shared or the rejection secret.
        var difference: UInt8 = 0
        for i in 0..<ciphertext.count {
            difference |= ciphertext[i] ^ again[i]
        }
        let mask = UInt8(truncatingIfNeeded: -Int(difference != 0 ? 1 : 0))
        return (0..<32).map { (shared[$0] & ~mask) | (rejected[$0] & mask) }
    }
}
