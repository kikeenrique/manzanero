import CryptoKit
import Foundation
import Testing
@testable import Manzanero

/// The large-number arithmetic and the SRP exchange of the tool's own
/// pairing, checked on the Mac: against small known answers, against the
/// group's own prime, and against a server written here from the same RFC.
struct RemotePairingSRPTests {
    @Test func bytesRoundTripAndPad() {
        #expect(BigNumber(bytes: [0, 0, 1, 2]).bytes == [1, 2])
        #expect(BigNumber(bytes: [0]).bytes == [0] && BigNumber().isZero)
        #expect(BigNumber(bytes: [1, 2]).bytes(paddedTo: 4) == [0, 0, 1, 2])
        let nine: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
        #expect(BigNumber(bytes: nine).bytes == nine && BigNumber(bytes: nine).bitWidth == 65)
    }

    @Test func arithmeticCarriesAcrossLimbs() {
        let top = BigNumber(UInt64.max)
        #expect((top + BigNumber(1)).bytes == [1, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(top + BigNumber(1) - BigNumber(1) == top)
        // (2^64 - 1)^2 = 2^128 - 2^65 + 1
        #expect((top * top).bytes == [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0, 0, 0, 0, 0, 0, 0, 1])
        #expect((top * top).modulo(top).isZero)
        #expect(BigNumber(1000).modulo(BigNumber(7)) == BigNumber(6))
        #expect(BigNumber(3) < BigNumber(4) && top < top + BigNumber(1))
    }

    @Test func powersMatchKnownAnswers() {
        // 4^13 mod 497 = 445, the textbook example.
        #expect(BigNumber(4).power(BigNumber(13), modulo: BigNumber(497)) == BigNumber(445))
        #expect(BigNumber(7).power(BigNumber(), modulo: BigNumber(13)) == BigNumber(1))
        // Fermat on the group's 3072-bit prime: g^(N-1) = 1.
        let modulus = PairingSRP.modulus
        #expect(modulus.bitWidth == 3072)
        #expect(PairingSRP.generator.power(modulus - BigNumber(1), modulo: modulus) == BigNumber(1))
        // And across two limbs: 3^(2^64) mod (2^89 - 1), squared 64 times.
        let mersenne = BigNumber(limbs: [UInt64.max, (1 << 25) - 1])
        var squared = BigNumber(3)
        for _ in 0..<64 { squared = (squared * squared).modulo(mersenne) }
        #expect(BigNumber(3).power(BigNumber(limbs: [0, 1]), modulo: mersenne) == squared)
    }

    /// A server with the verifier for the same PIN arrives at the same key
    /// and accepts the client's proof; one with another PIN does not.
    @Test func theClientAgreesWithAServerThatKnowsThePIN() throws {
        let modulus = PairingSRP.modulus, generator = PairingSRP.generator
        let salt: [UInt8] = (0..<16).map { UInt8($0 * 7 + 1) }
        let pin = Array("493827".utf8)
        func digest(_ parts: [UInt8]...) -> [UInt8] {
            var hasher = SHA512()
            for part in parts { hasher.update(data: part) }
            return Array(hasher.finalize())
        }
        // The server: v = g^x, B = k v + g^b.
        let verifier = generator.power(PairingSRP.privateValue(salt: salt, password: pin), modulo: modulus)
        let serverSecret = BigNumber(bytes: (0..<32).map { UInt8(200 - $0) })
        let serverPublic = (PairingSRP.multiplier * verifier + generator.power(serverSecret, modulo: modulus)).modulo(modulus)

        let secret: [UInt8] = (0..<32).map { UInt8($0 + 3) }
        let session = try #require(PairingSRP.session(secret: secret, password: pin, salt: salt, serverPublicKey: serverPublic.bytes))
        #expect(session.publicKey.count == 384 && session.proof.count == 64 && session.key.count == 64)

        // The server: S = (A v^u)^b, K = H(S).
        let clientPublic = BigNumber(bytes: session.publicKey)
        let u = BigNumber(bytes: digest(clientPublic.bytes, serverPublic.bytes))
        let shared = (clientPublic * verifier.power(u, modulo: modulus)).modulo(modulus).power(serverSecret, modulo: modulus)
        #expect(digest(shared.bytes) == session.key)
        #expect(digest(clientPublic.bytes, session.proof, session.key) == session.serverProof)

        let wrong = try #require(PairingSRP.session(secret: secret, password: Array("000000".utf8), salt: salt, serverPublicKey: serverPublic.bytes))
        #expect(wrong.key != session.key && wrong.proof != session.proof)
        // A public value that is a multiple of the modulus is refused.
        #expect(PairingSRP.session(secret: secret, password: pin, salt: salt, serverPublicKey: modulus.bytes) == nil)
    }
}
