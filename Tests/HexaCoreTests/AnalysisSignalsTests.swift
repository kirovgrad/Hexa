import XCTest
@testable import HexaCore

final class AnalysisSignalsTests:XCTestCase {
    func testKnownMagicAndMIMEAndContainerSubtypes() {
        for rule in FileMagic.rules {
            var data = Data(repeating:0,count:rule.offset);data.append(contentsOf:rule.bytes)
            let result = FileMagic.identify(ByteStore(data))
            XCTAssertEqual(result.mime,rule.mime,rule.name)
        }
        XCTAssertEqual(FileMagic.identify(ByteStore(Data("RIFF0000WEBP".utf8))).mime,"image/webp")
        XCTAssertEqual(FileMagic.identify(ByteStore(Data([0,0,0,24])+Data("ftypavif".utf8))).mime,"image/avif")
        XCTAssertEqual(FileMagic.identify(ByteStore(Data([0xca,0xfe,0xba,0xbe,0,0,0,61,0,12]))).mime,"application/java-vm")
        XCTAssertEqual(FileMagic.identify(ByteStore(Data("{\"test\": 1}".utf8))).mime,"application/json")
        XCTAssertEqual(FileMagic.identify(ByteStore(Data("hello".utf8))).mime,"text/plain")
        XCTAssertEqual(FileMagic.identify(ByteStore(Data([0,255,1]))).mime,"application/octet-stream")
        var fat = ExecutableFixtures.fat()
        ExecutableFixtures.put(&fat,4,61,4,false)
        XCTAssertEqual(FileMagic.identify(ByteStore(fat)).format,.machO,"A plausible FAT descriptor disambiguates architecture count 61 from Java major version 61")
    }
    func testEveryByteBelongsToExactlyOneType() throws {
        let report = try ByteAnalysis.analyze(ByteStore(Data(0...255)))
        XCTAssertEqual(report.signals.byteTypes,[1,6,94,27,127,1])
        XCTAssertEqual(report.signals.byteTypes.reduce(0,+),256)
        XCTAssertEqual(report.signals.layers.reduce(0,+),256)
        XCTAssertEqual(report.signals.digrams.reduce(0,+),255)
        XCTAssertEqual(report.signals.digrams[0*256+1],1)
    }
    func testWindowHighestAverageAndGlobalEntropyAreDistinct() throws {
        var data = Data(repeating:0,count:4096)
        for _ in 0..<16 { data.append(Data(0...255)) }
        let report = try ByteAnalysis.analyze(ByteStore(data)), signals = report.signals
        XCTAssertEqual(signals.windows.count,2);XCTAssertEqual(signals.windows[0].entropy,0)
        XCTAssertEqual(signals.highestEntropy,8,accuracy:0.000001)
        XCTAssertEqual(signals.averageEntropy,4,accuracy:0.000001)
        XCTAssertGreaterThan(report.entropy,signals.averageEntropy)
        XCTAssertEqual(signals.windows.map(\.range),[0..<4096,4096..<8192])
    }
    func testRangeAndPairsAcrossChunks() throws {
        var data = Data(repeating:0,count:1_048_590);data[7+1_048_575] = 0xAB;data[7+1_048_576] = 0xCD
        let report = try ByteAnalysis.analyze(ByteStore(data),range:7..<data.count)
        XCTAssertEqual(report.signals.digrams[0xAB*256+0xCD],1)
        XCTAssertEqual(report.signals.digrams.reduce(0,+),data.count-8)
        XCTAssertEqual(report.signals.layers.reduce(0,+),data.count-7)
        XCTAssertEqual(report.signals.windows.first?.range.lowerBound,7)
        XCTAssertEqual(report.signals.windows.last?.range.upperBound,data.count)
    }
    func testAESGenerationAndCryptoAcrossChunkBoundary() throws {
        let aes = try XCTUnwrap(CryptographicConstants.signatures.first { $0.name == "AES S-box" })
        XCTAssertEqual(Array(aes.bytes.prefix(16)),[0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76])
        let inverse = try XCTUnwrap(CryptographicConstants.signatures.first { $0.name == "AES inverse S-box" })
        XCTAssertEqual(Array(inverse.bytes.prefix(16)),[0x52,0x09,0x6a,0xd5,0x30,0x36,0xa5,0x38,0xbf,0x40,0xa3,0x9e,0x81,0xf3,0xd7,0xfb])
        var data = Data(repeating:0,count:1_048_573);data.append(contentsOf:aes.bytes);data.append(Data(repeating:0,count:12))
        let matches = try ByteAnalysis.analyze(ByteStore(data)).signals.cryptoMatches.filter { $0.name == aes.name }
        XCTAssertEqual(matches.count,1);XCTAssertEqual(matches.first?.range,1_048_573..<1_048_829)
    }
    func testEveryCryptoSignatureAndBothEndiannesses() throws {
        for signature in CryptographicConstants.signatures {
            let data = Data([0x77,0x88])+Data(signature.bytes)+Data([0x77,0x88])
            let report = try ByteAnalysis.analyze(ByteStore(data),range:2..<2+signature.bytes.count)
            XCTAssertTrue(report.signals.cryptoMatches.contains { $0.name == signature.name && $0.encoding == signature.encoding && $0.range == 2..<2+signature.bytes.count },signature.id)
        }
    }
    func testCryptoCapAndNoFalseProofOfEncryption() throws {
        let data = Data(String(repeating:"expand 32-byte k",count:2010).utf8)
        let report = try ByteAnalysis.analyze(ByteStore(data))
        XCTAssertEqual(report.signals.cryptoMatches.count,2000);XCTAssertTrue(report.signals.cryptoTruncated)
        XCTAssertNotEqual(report.signals.assessment.title,"Encryption container identified")
        let gzip = try ByteAnalysis.analyze(ByteStore(Data([0x1f,0x8b,8])+Data(repeating:0,count:4096)))
        XCTAssertEqual(gzip.signals.assessment.title,"Compression format identified")
        let encrypted = try ByteAnalysis.analyze(ByteStore(Data("Salted__00000000".utf8)))
        XCTAssertEqual(encrypted.signals.assessment.title,"Encryption container identified")
        let uniform = try ByteAnalysis.analyze(ByteStore(Data((0..<4096).map { UInt8(truncatingIfNeeded:$0) })))
        XCTAssertEqual(uniform.signals.assessment.title,"Possibly compressed or encrypted")
    }
    func testLargeAnalysisKeepsAllBytesWithBoundedChartResolution() throws {
        var data = Data(repeating:0,count:4_194_305); data[data.count-1] = 255
        let report = try ByteAnalysis.analyze(ByteStore(data)), signals = report.signals
        XCTAssertLessThanOrEqual(signals.windows.count,1024); XCTAssertLessThanOrEqual(signals.layerCount,256)
        XCTAssertEqual(signals.byteTypes[5],1); XCTAssertEqual(signals.layers.reduce(0,+),data.count)
        XCTAssertEqual(signals.digrams.reduce(0,+),data.count-1)
        XCTAssertEqual(signals.windows.last?.range.upperBound,data.count)
        XCTAssertEqual(signals.windows.map { $0.range.count }.reduce(0,+),data.count)
    }
    func testAnalysisAndStructureCancellation() async throws {
        for structure in [false,true] {
            let task = Task {
                while !Task.isCancelled { await Task.yield() }
                let store = ByteStore(ExecutableFixtures.mach())
                if structure { _ = try BinaryStructure.parse(store) }
                else { _ = try ByteAnalysis.analyze(store) }
            }
            task.cancel()
            do { try await task.value; XCTFail("Expected cancellation") }
            catch is CancellationError { }
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }
    func testEmptySingleByteAndFinalPartialWindow() throws {
        for count in [0,1,4097] {
            let signals = try ByteAnalysis.analyze(ByteStore(Data(repeating:255,count:count))).signals
            XCTAssertEqual(signals.averageEntropy,0);XCTAssertEqual(signals.highestEntropy,0)
            XCTAssertEqual(signals.digrams.reduce(0,+),max(0,count-1));XCTAssertEqual(signals.layers.reduce(0,+),count)
            XCTAssertEqual(signals.windows.map { $0.range.count }.reduce(0,+),count)
        }
    }
}
