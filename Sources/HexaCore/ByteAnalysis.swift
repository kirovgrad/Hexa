import Foundation
import CryptoKit

public struct AnalysisReport: Sendable {
    public let id = UUID()
    public let count: Int
    public let sha256: String
    public let sha512: String
    public let md5: String
    public let crc32: String
    public let histogram: [Int]
    public let entropy: Double
    public let printable: Int
    public let zeroes: Int
    public let signals: AnalysisSignals
}

public struct FoundString: Identifiable, Sendable {
    public var id: Int { offset }
    public let offset: Int
    public let length: Int
    public let text: String
}

public struct DifferenceReport: Sendable {
    public let ranges: [Range<Int>]
    public let differingBytes: Int
    public let otherCount: Int
    public let truncated: Bool
}

public enum ByteAnalysis {
    private static let crcTable: [UInt32] = (0..<256).map { number in
        var value = UInt32(number)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB88320 ^ (value >> 1) : value >> 1 }
        return value
    }

    public static func analyze(_ store: ByteStore, range: Range<Int>? = nil) throws -> AnalysisReport {
        let range = range ?? 0..<store.count
        guard range.lowerBound >= 0, range.upperBound <= store.count else { throw HexaError.message("Invalid analysis range.") }
        var sha256 = SHA256(), sha512 = SHA512(), md5 = Insecure.MD5()
        var crc: UInt32 = 0xFFFFFFFF, histogram = Array(repeating: 0, count: 256), printable = 0
        var signals = SignalAccumulator(range: range)
        var offset = range.lowerBound
        while offset < range.upperBound {
            try Task.checkCancellation()
            let end = offset + min(1_048_576, range.upperBound - offset)
            let data = store.data(in: offset..<end)
            sha256.update(data: data); sha512.update(data: data); md5.update(data: data)
            for byte in data { histogram[Int(byte)] += 1; crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8); if (32...126).contains(byte) { printable += 1 } }
            try signals.consume(data, final: end == range.upperBound)
            offset = end
        }
        let entropy = range.isEmpty ? 0 : histogram.filter { $0 > 0 }.reduce(0.0) { sum, n in
            let probability = Double(n) / Double(range.count); return sum - probability * log2(probability)
        }
        return AnalysisReport(count: range.count, sha256: ByteFormatting.hex(Data(sha256.finalize()), separator: "").lowercased(),
                              sha512: ByteFormatting.hex(Data(sha512.finalize()), separator: "").lowercased(),
                              md5: ByteFormatting.hex(Data(md5.finalize()), separator: "").lowercased(),
                              crc32: String(format: "%08X", crc ^ 0xFFFFFFFF), histogram: histogram, entropy: entropy,
                              printable: printable, zeroes: histogram[0], signals: signals.finish(identity: FileMagic.identify(store, range: range)))
    }

    public static func strings(in store: ByteStore, minimumLength: Int = 4, limit: Int = 10_000) throws -> (strings: [FoundString], truncated: Bool) {
        guard minimumLength >= 1 else { throw HexaError.message("Minimum string length must be positive.") }
        var results: [FoundString] = [], runStart = 0, runLength = 0, preview: [UInt8] = []
        func finishRun() -> Bool {
            guard runLength >= minimumLength else { return false }
            guard results.count < limit else { return true }
            results.append(FoundString(offset: runStart, length: runLength, text: String(decoding: preview, as: UTF8.self) + (runLength > preview.count ? "…" : "")))
            return false
        }
        var offset = 0
        while offset < store.count {
            try Task.checkCancellation()
            let end = offset + min(1_048_576, store.count - offset)
            for byte in store.data(in: offset..<end) {
                if (32...126).contains(byte) {
                    if runLength == 0 { runStart = offset }
                    runLength += 1
                    if preview.count < 512 { preview.append(byte) }
                } else {
                    if finishRun() { return (results, true) }
                    runLength = 0; preview.removeAll(keepingCapacity: true)
                }
                offset += 1
            }
        }
        if finishRun() { return (results, true) }
        return (results, false)
    }

    /// Offset-aligned comparison: insertions are deliberately not realigned like a text diff.
    public static func compare(_ a: ByteStore, _ b: ByteStore, limit: Int = 100_000) throws -> DifferenceReport {
        var ranges: [Range<Int>] = [], run: Int?, differing = 0, truncated = false, offset = 0
        let count = max(a.count, b.count)
        func append(_ range: Range<Int>) { if ranges.count < limit { ranges.append(range) } else { truncated = true } }
        while offset < count {
            try Task.checkCancellation()
            let end = offset + min(1_048_576, count - offset)
            let left = Array(a.data(in: min(offset, a.count)..<min(end, a.count)))
            let right = Array(b.data(in: min(offset, b.count)..<min(end, b.count)))
            for i in 0..<(end - offset) {
                let changed = i >= left.count || i >= right.count || left[i] != right[i]
                if changed { differing += 1; if run == nil { run = offset + i } }
                else if let start = run { append(start..<(offset + i)); run = nil }
            }
            offset = end
        }
        if let start = run { append(start..<count) }
        return DifferenceReport(ranges: ranges, differingBytes: differing, otherCount: b.count, truncated: truncated)
    }

    public static func unsigned(_ bytes: Data, littleEndian: Bool) -> UInt64? {
        guard !bytes.isEmpty, bytes.count <= 8 else { return nil }
        return (littleEndian ? Array(bytes.reversed()) : Array(bytes)).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    public static func signed(_ bytes: Data, littleEndian: Bool) -> Int64? {
        guard let value = unsigned(bytes, littleEndian: littleEndian) else { return nil }
        let shift = 64 - bytes.count * 8
        return Int64(bitPattern: value << shift) >> shift
    }
}
