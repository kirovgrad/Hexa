import XCTest
@testable import HexaCore

final class ByteStoreTests: XCTestCase {
    func testInsertOverwriteDeleteAndSnapshot() throws {
        var store = ByteStore(Data([0, 1, 2, 3, 4]))
        let original = store
        try store.replace(2..<2, with: Data([8, 9]))
        XCTAssertEqual(store.data(in: 0..<store.count), Data([0, 1, 8, 9, 2, 3, 4]))
        try store.replace(1..<5, with: Data([6]))
        XCTAssertEqual(store.data(in: 0..<store.count), Data([0, 6, 3, 4]))
        try store.replace(0..<store.count, with: Data())
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(original.data(in: 0..<5), Data([0, 1, 2, 3, 4]))
    }
    func testReadsAcrossPiecesAndClamps() throws {
        var store = ByteStore(Data([0, 1, 2, 3]))
        try store.replace(2..<2, with: Data([4, 5]))
        XCTAssertEqual(store.data(in: 1..<5), Data([1, 4, 5, 2]))
        XCTAssertEqual(store.data(in: -10..<20), Data([0, 1, 4, 5, 2, 3]))
        XCTAssertNil(store.byte(at: -1)); XCTAssertNil(store.byte(at: 6))
        XCTAssertEqual(store.byte(at: 4), 2)
        XCTAssertEqual(store.editedRanges(in: 1..<5), [2..<4])
    }
    func testInvalidEditIsTransactional() throws {
        var store = ByteStore(Data([1, 2]))
        XCTAssertThrowsError(try store.replace(0..<3, with: Data()))
        XCTAssertThrowsError(try store.replace(-1..<1, with: Data()))
        XCTAssertEqual(store.count, 2)
    }
    func testBatchReplacement() throws {
        var store = ByteStore(Data("one two one".utf8))
        try store.replaceAll([0..<3, 8..<11], with: Data("1".utf8))
        XCTAssertEqual(String(decoding: store.data(in: 0..<store.count), as: UTF8.self), "1 two 1")
        XCTAssertThrowsError(try store.replaceAll([0..<2, 1..<3], with: Data()))
    }
    func testRandomEditsAgainstDataReference() throws {
        var rng = Generator(), reference = Data((0..<128).map(UInt8.init)), store = ByteStore(reference)
        var snapshots: [(ByteStore, Data)] = []
        for iteration in 0..<2_000 {
            let start = Int.random(in: 0...reference.count, using: &rng)
            let end = Int.random(in: start...reference.count, using: &rng)
            let insertion = Data((0..<Int.random(in: 0...32, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            if iteration % 100 == 0 { snapshots.append((store, reference)) }
            reference.replaceSubrange(start..<end, with: insertion); try store.replace(start..<end, with: insertion)
            XCTAssertEqual(store.count, reference.count)
            XCTAssertEqual(store.data(in: 0..<store.count), reference, "Edit \(iteration)")
            for i in reference.indices { XCTAssertEqual(store.byte(at: i), reference[i]) }
        }
        for (snapshot, expected) in snapshots { XCTAssertEqual(snapshot.data(in: 0..<snapshot.count), expected) }
    }
    func testPrivateSnapshotSurvivesExternalTruncation() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("input.bin")
        try Data(repeating: 0xAB, count: 2_000_000).write(to: url)
        let store = try ByteStore.open(url)
        try Data([1]).write(to: url)
        XCTAssertEqual(store.count, 2_000_000)
        XCTAssertEqual(store.byte(at: 1_999_999), 0xAB)
    }
    func testAtomicSaveAndExportAndPermissions() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("saved.bin")
        try Data([1]).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let stamp = try FileStamp(url: url), store = ByteStore(Data([4, 5, 6]))
        try store.write(to: url, expectedStamp: stamp)
        XCTAssertEqual(try Data(contentsOf: url), Data([4, 5, 6]))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path))[.posixPermissions] as? Int, 0o640)
        let export = directory.appendingPathComponent("selection.bin")
        try store.write(to: export, range: 1..<3)
        XCTAssertEqual(try Data(contentsOf: export), Data([5, 6]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["saved.bin", "selection.bin"])
    }
    func testSaveRefusesExternalChangesAndCleansTemporaryFile() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("saved.bin")
        try Data([1]).write(to: url); let stamp = try FileStamp(url: url)
        try Data([9, 9]).write(to: url)
        XCTAssertThrowsError(try ByteStore(Data([2])).write(to: url, expectedStamp: stamp))
        XCTAssertEqual(try Data(contentsOf: url), Data([9, 9]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["saved.bin"])
    }
    func testOpenRejectsDirectory() throws { XCTAssertThrowsError(try ByteStore.open(FileManager.default.temporaryDirectory)) }
    private func temporaryDirectory() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }
}

struct Generator: RandomNumberGenerator {
    private var state: UInt64 = 0xC0FFEE
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}
