import CryptoKit
import Foundation

/// An unsigned integer of any size, for the one place the tool needs one:
/// the SRP exchange of Apple's remote pairing, whose numbers are 3072 bits
/// (docs/transport.md#a-pairing-of-the-tools-own). Limbs are 64 bits, least
/// significant first, with no zero limb on top. Not constant time: the
/// secret here is a six-digit PIN shown on a television, used once.
struct BigNumber: Equatable, Comparable {
    private(set) var limbs: [UInt64]

    init(limbs: [UInt64] = []) {
        self.limbs = limbs
        while self.limbs.last == 0 { self.limbs.removeLast() }
    }

    init(_ value: UInt64) { self.init(limbs: [value]) }

    /// Big-endian bytes, as SRP writes its numbers.
    init(bytes: some Sequence<UInt8>) {
        var limbs: [UInt64] = [], limb: UInt64 = 0, shift: UInt64 = 0
        for byte in Array(bytes).reversed() {
            limb |= UInt64(byte) << shift
            shift += 8
            if shift == 64 { limbs.append(limb); limb = 0; shift = 0 }
        }
        if shift > 0 { limbs.append(limb) }
        self.init(limbs: limbs)
    }

    var isZero: Bool { limbs.isEmpty }

    /// Big-endian bytes without leading zeros; one zero byte for zero.
    var bytes: [UInt8] {
        var out: [UInt8] = []
        for limb in limbs.reversed() { for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: limb >> UInt64(shift))) } }
        let significant = Array(out.drop { $0 == 0 })
        return significant.isEmpty ? [0] : significant
    }

    /// Big-endian bytes padded with zeros on the left to `count`.
    func bytes(paddedTo count: Int) -> [UInt8] {
        let minimal = isZero ? [] : bytes
        return [UInt8](repeating: 0, count: max(0, count - minimal.count)) + minimal
    }

    var bitWidth: Int { limbs.last.map { (limbs.count - 1) * 64 + (64 - $0.leadingZeroBitCount) } ?? 0 }

    func bit(_ index: Int) -> Bool {
        let limb = index / 64
        return limb < limbs.count && (limbs[limb] >> UInt64(index % 64)) & 1 == 1
    }

    static func < (a: BigNumber, b: BigNumber) -> Bool {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
        for index in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[index] != b.limbs[index] {
            return a.limbs[index] < b.limbs[index]
        }
        return false
    }

    static func + (a: BigNumber, b: BigNumber) -> BigNumber {
        var out: [UInt64] = [], carry = false
        for index in 0..<max(a.limbs.count, b.limbs.count) {
            let x = index < a.limbs.count ? a.limbs[index] : 0, y = index < b.limbs.count ? b.limbs[index] : 0
            let (sum, first) = x.addingReportingOverflow(y)
            let (total, second) = sum.addingReportingOverflow(carry ? 1 : 0)
            out.append(total)
            carry = first || second
        }
        if carry { out.append(1) }
        return BigNumber(limbs: out)
    }

    /// `a - b`, for `a >= b`.
    static func - (a: BigNumber, b: BigNumber) -> BigNumber {
        precondition(a >= b, "BigNumber subtraction below zero")
        var out: [UInt64] = [], borrow = false
        for index in 0..<a.limbs.count {
            let y = index < b.limbs.count ? b.limbs[index] : 0
            let (difference, first) = a.limbs[index].subtractingReportingOverflow(y)
            let (total, second) = difference.subtractingReportingOverflow(borrow ? 1 : 0)
            out.append(total)
            borrow = first || second
        }
        return BigNumber(limbs: out)
    }

    static func * (a: BigNumber, b: BigNumber) -> BigNumber {
        guard !a.isZero, !b.isZero else { return BigNumber() }
        var out = [UInt64](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            for j in 0..<b.limbs.count {
                let (high, low) = a.limbs[i].multipliedFullWidth(by: b.limbs[j])
                let (sum, first) = out[i + j].addingReportingOverflow(low)
                let (total, second) = sum.addingReportingOverflow(carry)
                out[i + j] = total
                carry = high &+ (first ? 1 : 0) &+ (second ? 1 : 0)
            }
            out[i + b.limbs.count] = carry
        }
        return BigNumber(limbs: out)
    }

    private func doubled() -> BigNumber {
        var out: [UInt64] = [], carry: UInt64 = 0
        for limb in limbs { out.append(limb << 1 | carry); carry = limb >> 63 }
        if carry == 1 { out.append(1) }
        return BigNumber(limbs: out)
    }

    /// The remainder, one bit at a time: slow, and used a handful of times.
    func modulo(_ modulus: BigNumber) -> BigNumber {
        precondition(!modulus.isZero, "BigNumber modulo zero")
        guard self >= modulus else { return self }
        var remainder = BigNumber()
        for index in stride(from: bitWidth - 1, through: 0, by: -1) {
            remainder = remainder.doubled()
            if bit(index) { remainder = remainder + BigNumber(1) }
            if remainder >= modulus { remainder = remainder - modulus }
        }
        return remainder
    }

    /// `self ^ exponent mod modulus` for an odd modulus, by Montgomery
    /// multiplication.
    func power(_ exponent: BigNumber, modulo modulus: BigNumber) -> BigNumber {
        precondition(modulus.limbs.first.map { $0 & 1 == 1 } ?? false, "BigNumber power needs an odd modulus")
        let size = modulus.limbs.count
        // -modulus^-1 mod 2^64, by Newton's iteration.
        var inverse: UInt64 = 1
        for _ in 0..<6 { inverse = inverse &* (2 &- modulus.limbs[0] &* inverse) }
        let negatedInverse = 0 &- inverse
        let one = BigNumber(limbs: [UInt64](repeating: 0, count: size) + [1]).modulo(modulus)
        let oneSquared = (one * one).modulo(modulus)

        func padded(_ value: BigNumber) -> [UInt64] { value.limbs + [UInt64](repeating: 0, count: size - value.limbs.count) }
        let n = padded(modulus)

        // a * b / 2^(64 * size) mod modulus, on values below the modulus.
        func multiply(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
            var t = [UInt64](repeating: 0, count: size + 2)
            for i in 0..<size {
                var carry: UInt64 = 0
                for j in 0..<size {
                    let (high, low) = a[j].multipliedFullWidth(by: b[i])
                    let (sum, first) = t[j].addingReportingOverflow(low)
                    let (total, second) = sum.addingReportingOverflow(carry)
                    t[j] = total
                    carry = high &+ (first ? 1 : 0) &+ (second ? 1 : 0)
                }
                let (top, overflow) = t[size].addingReportingOverflow(carry)
                t[size] = top
                t[size + 1] = overflow ? 1 : 0
                let m = t[0] &* negatedInverse
                var (high, low) = m.multipliedFullWidth(by: n[0])
                carry = high &+ (t[0].addingReportingOverflow(low).overflow ? 1 : 0)
                for j in 1..<size {
                    (high, low) = m.multipliedFullWidth(by: n[j])
                    let (sum, first) = t[j].addingReportingOverflow(low)
                    let (total, second) = sum.addingReportingOverflow(carry)
                    t[j - 1] = total
                    carry = high &+ (first ? 1 : 0) &+ (second ? 1 : 0)
                }
                let (last, lastOverflow) = t[size].addingReportingOverflow(carry)
                t[size - 1] = last
                t[size] = t[size + 1] &+ (lastOverflow ? 1 : 0)
            }
            var result = BigNumber(limbs: Array(t[0...size]))
            if result >= modulus { result = result - modulus }
            return padded(result)
        }

        let base = multiply(padded(modulo(modulus)), padded(oneSquared))
        var result = padded(one)
        for index in stride(from: exponent.bitWidth - 1, through: 0, by: -1) {
            result = multiply(result, result)
            if exponent.bit(index) { result = multiply(result, base) }
        }
        return BigNumber(limbs: multiply(result, padded(BigNumber(1))))
    }
}

/// The client's half of SRP-6a as Apple's pairing uses it: SHA-512, the
/// 3072-bit group of RFC 5054, the user name `Pair-Setup` and the PIN as the
/// password. Each hash input is written as the reference implementation
/// writes it (github.com/jkcoxson/idevice-srp, MIT): the two public values
/// without padding for `u` and in the server's proof, padded in the client's.
struct PairingSRP {
    static let generator = BigNumber(5)
    static let modulus = BigNumber(bytes: stride(from: 0, to: modulusHex.count, by: 2).map { offset -> UInt8 in
        let start = modulusHex.index(modulusHex.startIndex, offsetBy: offset)
        return UInt8(modulusHex[start..<modulusHex.index(start, offsetBy: 2)], radix: 16)!
    })
    static let modulusBytes = 384
    static let userName = Array("Pair-Setup".utf8)

    /// What the client sends, and what it expects back.
    struct Session: Equatable {
        /// `A`, 384 bytes.
        let publicKey: [UInt8]
        /// `M1`, the client's proof.
        let proof: [UInt8]
        /// `M2`, the proof the server must answer with.
        let serverProof: [UInt8]
        /// `K`, the session key.
        let key: [UInt8]
    }

    private static func hash(_ parts: [UInt8]...) -> [UInt8] {
        var hasher = SHA512()
        for part in parts { hasher.update(data: part) }
        return Array(hasher.finalize())
    }

    /// `x`, the private value derived from the salt and the password.
    static func privateValue(salt: [UInt8], password: [UInt8]) -> BigNumber {
        BigNumber(bytes: hash(salt, hash(userName, Array(":".utf8), password)))
    }

    static var multiplier: BigNumber {
        BigNumber(bytes: hash(modulus.bytes, generator.bytes(paddedTo: modulusBytes)))
    }

    /// Answers the server's salt and public value `B` with the client's
    /// secret `a`. Nil when `B` is a multiple of the modulus, which no
    /// honest server sends.
    static func session(secret: [UInt8], password: [UInt8], salt: [UInt8], serverPublicKey: [UInt8]) -> Session? {
        let a = BigNumber(bytes: secret), b = BigNumber(bytes: serverPublicKey)
        guard !b.modulo(modulus).isZero else { return nil }
        let publicValue = generator.power(a, modulo: modulus)
        let u = BigNumber(bytes: hash(publicValue.bytes, b.bytes))
        let x = privateValue(salt: salt, password: password)
        let masked = (multiplier * generator.power(x, modulo: modulus)).modulo(modulus)
        let base = (modulus + b - masked).modulo(modulus)
        let key = hash(base.power(u * x + a, modulo: modulus).bytes)
        let groupHash = zip(hash(modulus.bytes), hash(generator.bytes)).map { $0 ^ $1 }
        let proof = hash(groupHash, hash(userName), salt, publicValue.bytes(paddedTo: modulusBytes), b.bytes(paddedTo: modulusBytes), key)
        return Session(publicKey: publicValue.bytes(paddedTo: modulusBytes), proof: proof,
                       serverProof: hash(publicValue.bytes, proof, key), key: key)
    }

    /// The 3072-bit prime of RFC 5054 (RFC 3526 group 15).
    private static let modulusHex = """
        ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd\
        ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed\
        ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f\
        83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b\
        e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa0510\
        15728e5a8aaac42dad33170d04507a33a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7\
        abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864d87602733ec86a64521f2b18177b200c\
        bbe117577a615d6c770988c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a93ad2caffffffffffffffff
        """
}
