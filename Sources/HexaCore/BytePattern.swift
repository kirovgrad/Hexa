import Foundation

public enum TextEncoding: String, CaseIterable, Identifiable, Sendable {
    case utf8 = "UTF-8", ascii = "ASCII", latin1 = "Latin-1", utf16LE = "UTF-16 LE", utf16BE = "UTF-16 BE"
    public var id: String { rawValue }
    public var foundation: String.Encoding {
        switch self { case .utf8: return .utf8; case .ascii: return .ascii; case .latin1: return .isoLatin1; case .utf16LE: return .utf16LittleEndian; case .utf16BE: return .utf16BigEndian }
    }
    public func encode(_ text: String) throws -> Data {
        guard let data = text.data(using: foundation, allowLossyConversion: false) else { throw HexaError.message("This text cannot be represented as \(rawValue).") }
        return data
    }
}

public struct BytePattern: Sendable {
    public let values: [UInt8]
    public let masks: [UInt8]
    public var count: Int { values.count }
    public init(data: Data) { values = Array(data); masks = Array(repeating: 255, count: data.count) }
    /// Supports full-byte and half-byte wildcards: DE AD ?? B? ?F.
    public init(hex: String, wildcards: Bool = true) throws {
        let normalized = hex.replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .filter { !$0.isWhitespace && $0 != "," && $0 != "_" }
        let chars = Array(normalized)
        guard chars.count.isMultiple(of: 2) else { throw HexaError.message("Hex input needs two digits per byte, for example DE AD BE EF.") }
        var values: [UInt8] = [], masks: [UInt8] = []
        for index in stride(from: 0, to: chars.count, by: 2) {
            var value: UInt8 = 0, mask: UInt8 = 0
            for char in chars[index...index + 1] {
                value <<= 4; mask <<= 4
                if char == "?", wildcards { continue }
                guard let digit = char.hexDigitValue, digit < 16, char.isASCII else { throw HexaError.message("Invalid hex character ‘\(char)’. Use 0–9, A–F\(wildcards ? ", or ?" : "").") }
                value |= UInt8(digit); mask |= 15
            }
            values.append(value); masks.append(mask)
        }
        self.values = values; self.masks = masks
    }
    public static func parseOffset(_ input: String, relativeTo: Int = 0) throws -> Int {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "")
        let relative = text.hasPrefix("+") || text.hasPrefix("-")
        let negative = text.hasPrefix("-")
        if relative { text.removeFirst() }
        let radix = text.lowercased().hasPrefix("0x") ? 16 : 10
        if radix == 16 { text.removeFirst(2) }
        guard let magnitude = Int(text, radix: radix) else { throw HexaError.message("Enter a decimal offset or 0x-prefixed hexadecimal offset. Use + or − for a relative offset.") }
        let value = negative ? -magnitude : magnitude
        let (result, overflow) = relative ? relativeTo.addingReportingOverflow(value) : (value, false)
        guard !overflow, result >= 0 else { throw HexaError.message("The offset is outside the file.") }
        return result
    }
}

public struct SearchResults: Sendable {
    public let ranges: [Range<Int>]
    public let truncated: Bool
}

public enum ByteSearch {
    public static func find(in store: ByteStore, pattern: BytePattern, range: Range<Int>? = nil, limit: Int = 100_000) throws -> SearchResults {
        guard pattern.count > 0 else { throw HexaError.message("Enter a search pattern first.") }
        guard pattern.count <= 1_048_576 else { throw HexaError.message("Search patterns are limited to 1 MiB.") }
        let bounds = range ?? 0..<store.count
        guard bounds.lowerBound >= 0, bounds.upperBound <= store.count else { throw HexaError.message("Invalid search range.") }
        guard pattern.count <= bounds.count else { return SearchResults(ranges: [], truncated: false) }
        if pattern.masks.allSatisfy({ $0 == 255 }) { return try exactSearch(store, pattern.values, bounds: bounds, limit: limit) }
        // A wildcard-aware Horspool table skips candidates without missing partial-byte patterns.
        var skip = Array(repeating: pattern.count, count: 256)
        if pattern.count > 1 {
            for i in 0..<(pattern.count - 1) {
                if pattern.masks[i] == 255 { skip[Int(pattern.values[i])] = pattern.count - 1 - i }
                else { for byte in 0..<256 where UInt8(byte) & pattern.masks[i] == pattern.values[i] { skip[byte] = pattern.count - 1 - i } }
                if i & 0x3FFF == 0 { try Task.checkCancellation() }
            }
        }
        var hits: [Range<Int>] = [], start = bounds.lowerBound
        let lastStart = bounds.upperBound - pattern.count
        while start <= lastStart {
            try Task.checkCancellation()
            let candidates = min(1_048_576, lastStart - start + 1)
            let bytes = Array(store.data(in: start..<(start + candidates + pattern.count - 1)))
            var local = 0
            while local < candidates {
                if local & 0x3FFF == 0 { try Task.checkCancellation() }
                var i = pattern.count - 1
                while bytes[local + i] & pattern.masks[i] == pattern.values[i] {
                    if i & 0x3FFF == 0 { try Task.checkCancellation() }
                    if i == 0 { break }; i -= 1
                }
                if i == 0, bytes[local] & pattern.masks[0] == pattern.values[0] {
                    if hits.count == limit { return SearchResults(ranges: hits, truncated: true) }
                    hits.append((start + local)..<(start + local + pattern.count)); local += 1
                } else { local += skip[Int(bytes[local + pattern.count - 1])] }
            }
            start += candidates
        }
        return SearchResults(ranges: hits, truncated: false)
    }
    private static func exactSearch(_ store: ByteStore, _ needle: [UInt8], bounds: Range<Int>, limit: Int) throws -> SearchResults {
        var prefix = Array(repeating: 0, count: needle.count), matched = 0
        if needle.count > 1 {
            for i in 1..<needle.count {
                if i & 0x3FFF == 0 { try Task.checkCancellation() }
                while matched > 0, needle[i] != needle[matched] { matched = prefix[matched - 1] }
                if needle[i] == needle[matched] { matched += 1 }; prefix[i] = matched
            }
        }
        matched = 0
        var offset = bounds.lowerBound, hits: [Range<Int>] = []
        while offset < bounds.upperBound {
            try Task.checkCancellation()
            let end = offset + min(1_048_576, bounds.upperBound - offset)
            for byte in store.data(in: offset..<end) {
                if offset & 0x3FFF == 0 { try Task.checkCancellation() }
                while matched > 0, byte != needle[matched] { matched = prefix[matched - 1] }
                if byte == needle[matched] { matched += 1 }
                if matched == needle.count {
                    if hits.count == limit { return SearchResults(ranges: hits, truncated: true) }
                    hits.append((offset - needle.count + 1)..<(offset + 1)); matched = prefix[matched - 1]
                }
                offset += 1
            }
        }
        return SearchResults(ranges: hits, truncated: false)
    }
}

public enum ByteFormatting {
    public static func hex(_ data: Data, separator: String = " ") -> String { data.map { String(format: "%02X", $0) }.joined(separator: separator) }
    public static func dump(_ data: Data, offset: Int = 0, columns: Int = 16) -> String {
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count, by: columns).map { start in
            let row = bytes[start..<min(bytes.count, start + columns)]
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let text = row.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            return String(format: "%08llX  ", UInt64(offset + start)) + hex.padding(toLength: columns * 3 - 1, withPad: " ", startingAt: 0) + "  |" + text + "|"
        }.joined(separator: "\n")
    }
}
