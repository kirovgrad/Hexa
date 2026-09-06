import Foundation

public struct CryptoSignature: Identifiable, Sendable {
    public var id: String { name + encoding }
    public let name: String
    public let encoding: String
    public let bytes: [UInt8]
}
public struct CryptoMatch: Identifiable, Sendable {
    public var id: String { "\(range.lowerBound):\(name):\(encoding)" }
    public let name: String
    public let encoding: String
    public let range: Range<Int>
}

public enum CryptographicConstants {
    public static let signatures: [CryptoSignature] = {
        var result: [CryptoSignature] = []
        func words(_ name: String, _ values: [UInt64], width: Int = 4) {
            for little in [true,false] {
                let bytes = values.flatMap { value in (0..<width).map { UInt8(truncatingIfNeeded: value >> ((little ? $0 : width-1-$0)*8)) } }
                result.append(CryptoSignature(name:name,encoding:little ? "Little-endian words":"Big-endian words",bytes:bytes))
            }
        }
        words("SHA-256 initial state",[0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19])
        words("SHA-256 round constants (first 8)",[0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5])
        words("SHA-512 initial state",[0x6a09e667f3bcc908,0xbb67ae8584caa73b,0x3c6ef372fe94f82b,0xa54ff53a5f1d36f1,0x510e527fade682d1,0x9b05688c2b3e6c1f,0x1f83d9abfb41bd6b,0x5be0cd19137e2179],width:8)
        words("SHA-1 initial state",[0x67452301,0xefcdab89,0x98badcfe,0x10325476,0xc3d2e1f0])
        words("MD5 / SHA-1 shared initial words",[0x67452301,0xefcdab89,0x98badcfe,0x10325476])
        words("MD5 round constants (first 8)",[0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,0xf57c0faf,0x4787c62a,0xa8304613,0xfd469501])
        words("Blowfish P-array (first 8)",[0x243f6a88,0x85a308d3,0x13198a2e,0x03707344,0xa4093822,0x299f31d0,0x082efa98,0xec4e6c89])
        words("CRC-32 lookup table (first 4)",[0x00000000,0x77073096,0xee0e612c,0x990951ba])
        for text in ["expand 32-byte k","expand 16-byte k"] { result.append(CryptoSignature(name:"ChaCha / Salsa constant",encoding:"ASCII · \(text)",bytes:Array(text.utf8))) }
        func multiply(_ left: UInt8,_ right: UInt8) -> UInt8 {
            var a = left, b = right, result: UInt8 = 0
            for _ in 0..<8 { if b & 1 != 0 { result ^= a }; let high = a & 0x80; a <<= 1; if high != 0 { a ^= 0x1b }; b >>= 1 }
            return result
        }
        func rotate(_ value: UInt8,_ bits: Int) -> UInt8 { value << bits | value >> (8-bits) }
        let sbox: [UInt8] = (0..<256).map { input in
            var inverse: UInt8 = 0
            if input != 0 {
                var power: UInt8 = UInt8(input), exponent = 254, accumulator: UInt8 = 1
                while exponent > 0 { if exponent & 1 != 0 { accumulator = multiply(accumulator,power) }; power = multiply(power,power); exponent >>= 1 }
                inverse = accumulator
            }
            return inverse ^ rotate(inverse,1) ^ rotate(inverse,2) ^ rotate(inverse,3) ^ rotate(inverse,4) ^ 0x63
        }
        var inverse = Array(repeating:UInt8(0),count:256)
        for (i,byte) in sbox.enumerated() { inverse[Int(byte)] = UInt8(i) }
        result.append(CryptoSignature(name:"AES S-box",encoding:"Complete 256-byte table",bytes:sbox))
        result.append(CryptoSignature(name:"AES inverse S-box",encoding:"Complete 256-byte table",bytes:inverse))
        return result
    }()
}

/// One streaming scan for all signatures, with a four-byte prefix index and overlap between chunks.
struct CryptoScanner {
    private let signatures = CryptographicConstants.signatures
    private let lookup: [UInt32:[Int]]
    private let maximum: Int
    private var tail: [UInt8] = []
    private(set) var matches: [CryptoMatch] = []
    private(set) var truncated = false
    init() {
        var index: [UInt32:[Int]] = [:]
        for (i,signature) in CryptographicConstants.signatures.enumerated() { index[Self.prefix(signature.bytes,0),default:[]].append(i) }
        lookup = index; maximum = CryptographicConstants.signatures.map { $0.bytes.count }.max() ?? 4
    }
    private static func prefix(_ bytes: [UInt8],_ i: Int) -> UInt32 { UInt32(bytes[i]) << 24 | UInt32(bytes[i+1]) << 16 | UInt32(bytes[i+2]) << 8 | UInt32(bytes[i+3]) }
    mutating func consume(_ data: Data, offset: Int, final: Bool) throws {
        guard !truncated else { return }
        let bytes = tail + Array(data), start = offset-tail.count
        let end = final ? max(0,bytes.count-3) : max(0,bytes.count-maximum+1)
        if end > 0 {
            for i in 0..<end {
                if i & 0x3fff == 0 { try Task.checkCancellation() }
                guard let candidates = lookup[Self.prefix(bytes,i)] else { continue }
                for candidate in candidates {
                    let signature = signatures[candidate]
                    guard signature.bytes.count <= bytes.count-i, bytes[i..<(i+signature.bytes.count)].elementsEqual(signature.bytes) else { continue }
                    guard matches.count < 2_000 else { truncated = true; tail = []; return }
                    matches.append(CryptoMatch(name:signature.name,encoding:signature.encoding,range:(start+i)..<(start+i+signature.bytes.count)))
                }
            }
        }
        tail = final ? [] : Array(bytes[end...])
    }
}
