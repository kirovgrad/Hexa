import XCTest
@testable import HexaCore

final class SearchAndAnalysisTests: XCTestCase {
    func testHexParsing() throws {
        let p = try BytePattern(hex: "0xDE, ad _ ?? B? ?f")
        XCTAssertEqual(p.values, [0xDE, 0xAD, 0, 0xB0, 0x0F])
        XCTAssertEqual(p.masks, [255, 255, 0, 0xF0, 0x0F])
        XCTAssertThrowsError(try BytePattern(hex: "ABC"))
        XCTAssertThrowsError(try BytePattern(hex: "GG"))
        XCTAssertThrowsError(try BytePattern(hex: "??", wildcards: false))
    }
    func testOffsetsAndOverflow() throws {
        XCTAssertEqual(try BytePattern.parseOffset("0xFF"), 255)
        XCTAssertEqual(try BytePattern.parseOffset("+0x10", relativeTo: 20), 36)
        XCTAssertEqual(try BytePattern.parseOffset("-10", relativeTo: 20), 10)
        XCTAssertEqual(try BytePattern.parseOffset("1_024"), 1024)
        XCTAssertThrowsError(try BytePattern.parseOffset("-1"))
        XCTAssertThrowsError(try BytePattern.parseOffset("+1", relativeTo: Int.max))
        XCTAssertThrowsError(try BytePattern.parseOffset("0xFFFFFFFFFFFFFFFF"))
    }
    func testOverlappingMatchesAndLimit() throws {
        let store = ByteStore(Data("aaaa".utf8)), pattern = BytePattern(data: Data("aa".utf8))
        XCTAssertEqual(try ByteSearch.find(in: store, pattern: pattern).ranges, [0..<2, 1..<3, 2..<4])
        let limited = try ByteSearch.find(in: store, pattern: pattern, limit: 2)
        XCTAssertEqual(limited.ranges, [0..<2, 1..<3]); XCTAssertTrue(limited.truncated)
        XCTAssertFalse(try ByteSearch.find(in: store, pattern: pattern, limit: 3).truncated)
        XCTAssertThrowsError(try ByteSearch.find(in: store, pattern: BytePattern(data: Data())))
    }
    func testWildcardAndRangeSearch() throws {
        let store = ByteStore(Data([0xDE, 0xAD, 0xBE, 0xEF, 0xDE, 0xA1, 0xB3, 0xFF]))
        XCTAssertEqual(try ByteSearch.find(in: store, pattern: BytePattern(hex: "DE A? B? ?F")).ranges, [0..<4, 4..<8])
        XCTAssertEqual(try ByteSearch.find(in: store, pattern: BytePattern(hex: "DE ??"), range: 2..<8).ranges, [4..<6])
    }
    func testPatternsAcrossChunkBoundaryAndPieces() throws {
        var store = ByteStore(Data(repeating: 0, count: 1_048_600))
        try store.replace(1_048_574..<1_048_579, with: Data([0xDE, 0xAD, 0xBE, 0xEF, 0x12]))
        for hex in ["DE AD BE EF 12", "DE ?? B? ?F 12"] {
            XCTAssertEqual(try ByteSearch.find(in: store, pattern: BytePattern(hex: hex)).ranges, [1_048_574..<1_048_579])
        }
    }
    func testWildcardSearchAgainstNaiveOracle() throws {
        var rng = Generator()
        for _ in 0..<300 {
            let bytes = (0..<80).map { _ in UInt8.random(in: 0...15, using: &rng) }
            let count = Int.random(in: 1...8, using: &rng)
            let patternText = (0..<count).map { _ in Bool.random(using: &rng) ? "??" : String(format: "%02X", UInt8.random(in: 0...15, using: &rng)) }.joined()
            let pattern = try BytePattern(hex: patternText)
            var expected: [Range<Int>] = []
            for offset in 0...(bytes.count - count) {
                if (0..<count).allSatisfy({ bytes[offset + $0] & pattern.masks[$0] == pattern.values[$0] }) { expected.append(offset..<offset + count) }
            }
            XCTAssertEqual(try ByteSearch.find(in: ByteStore(Data(bytes)), pattern: pattern).ranges, expected, patternText)
        }
    }
    func testHashesAndCRCReferenceVectors() throws {
        let report = try ByteAnalysis.analyze(ByteStore(Data("123456789".utf8)))
        XCTAssertEqual(report.crc32, "CBF43926")
        XCTAssertEqual(report.md5, "25f9e794323b453885f5181f1b624d0b")
        XCTAssertEqual(report.sha256, "15e2b0d3c33891ebb0f1ef609ec419420c20e320ce94c65fbc8c3312448eb225")
        XCTAssertEqual(report.printable, 9)
        let empty = try ByteAnalysis.analyze(ByteStore())
        XCTAssertEqual(empty.sha256, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(empty.crc32, "00000000"); XCTAssertEqual(empty.entropy, 0)
    }
    func testEntropyAndSelectedAnalysis() throws {
        XCTAssertEqual(try ByteAnalysis.analyze(ByteStore(Data(0...255))).entropy, 8, accuracy: 0.00001)
        let report = try ByteAnalysis.analyze(ByteStore(Data([0, 1, 1, 255])), range: 1..<3)
        XCTAssertEqual(report.count, 2); XCTAssertEqual(report.histogram[1], 2); XCTAssertEqual(report.entropy, 0)
    }
    func testStringsAcrossChunkBoundaryAndLimit() throws {
        var data = Data(repeating: 0, count: 1_048_574); data.append(Data("HELLO\0WORLD".utf8))
        let result = try ByteAnalysis.strings(in: ByteStore(data))
        XCTAssertEqual(result.strings.map(\.text), ["HELLO", "WORLD"])
        XCTAssertEqual(result.strings.map(\.offset), [1_048_574, 1_048_580])
        XCTAssertTrue(try ByteAnalysis.strings(in: ByteStore(data), limit: 1).truncated)
    }
    func testComparisonDifferentSizesAndRanges() throws {
        let a = ByteStore(Data([0, 1, 2, 3])), b = ByteStore(Data([0, 8, 2, 9, 9]))
        let report = try ByteAnalysis.compare(a, b)
        XCTAssertEqual(report.ranges, [1..<2, 3..<5]); XCTAssertEqual(report.differingBytes, 3)
        XCTAssertTrue(try ByteAnalysis.compare(a, b, limit: 1).truncated)
        XCTAssertEqual(try ByteAnalysis.compare(a, a).differingBytes, 0)
        XCTAssertEqual(try ByteAnalysis.compare(ByteStore(), b).ranges, [0..<5])
    }
    func testNumericInterpretation() {
        XCTAssertEqual(ByteAnalysis.unsigned(Data([1, 2]), littleEndian: true), 513)
        XCTAssertEqual(ByteAnalysis.unsigned(Data([1, 2]), littleEndian: false), 258)
        XCTAssertEqual(ByteAnalysis.signed(Data([0xFF]), littleEndian: true), -1)
        XCTAssertEqual(ByteAnalysis.signed(Data([0, 0x80]), littleEndian: true), -32768)
        XCTAssertEqual(ByteAnalysis.signed(Data(repeating: 255, count: 8), littleEndian: true), -1)
        XCTAssertNil(ByteAnalysis.unsigned(Data(), littleEndian: true))
    }
    func testEncodingAndFormatting() throws {
        XCTAssertEqual(try TextEncoding.utf16LE.encode("A"), Data([65, 0]))
        XCTAssertEqual(try TextEncoding.utf16BE.encode("A"), Data([0, 65]))
        XCTAssertThrowsError(try TextEncoding.ascii.encode("λ"))
        XCTAssertEqual(ByteFormatting.hex(Data([0, 255])), "00 FF")
        XCTAssertTrue(ByteFormatting.dump(Data([65, 0]), offset: 16).hasPrefix("00000010  41 00"))
    }
    func testCancellation() async throws {
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try ByteSearch.find(in: ByteStore(Data(repeating: 0, count: 100)), pattern: BytePattern(hex: "00"))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { } catch { XCTFail("\(error)") }
    }
}
