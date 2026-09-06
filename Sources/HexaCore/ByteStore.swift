import Foundation
import Darwin

/// Immutable backing buffers make value snapshots cheap and safe to read on background tasks.
private final class ByteSource: @unchecked Sendable {
    let data: Data
    let temporaryURL: URL?
    init(data: Data, temporaryURL: URL? = nil) { self.data = data; self.temporaryURL = temporaryURL }
    deinit { if let url = temporaryURL { try? FileManager.default.removeItem(at: url) } }
}

public struct ByteStore: Sendable {
    private struct Piece: Sendable {
        let source: ByteSource
        var range: Range<Int>
        let edited: Bool
        var count: Int { range.count }
    }
    private var pieces: [Piece] = []
    private var ends: [Int] = []
    public private(set) var count = 0

    public init(_ data: Data = Data()) {
        if !data.isEmpty { pieces = [Piece(source: ByteSource(data: data), range: 0..<data.count, edited: false)] }
        rebuildIndex()
    }

    /// Work from a private copy (APFS clone when available), so external truncation cannot invalidate a mapping.
    public static func open(_ url: URL) throws -> ByteStore {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw HexaError.message("Only regular files can be opened. Device files and directories are not supported.")
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Hexa-\(UUID().uuidString).snapshot")
        let result = url.withUnsafeFileSystemRepresentation { from in
            copy.withUnsafeFileSystemRepresentation { to in
                copyfile(from, to, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_CLONE))
            }
        }
        guard result == 0 else {
            try? FileManager.default.removeItem(at: copy)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            let data = try Data(contentsOf: copy, options: .mappedIfSafe)
            var store = ByteStore()
            if !data.isEmpty { store.pieces = [Piece(source: ByteSource(data: data, temporaryURL: copy), range: 0..<data.count, edited: false)] }
            else { try? FileManager.default.removeItem(at: copy) }
            store.rebuildIndex()
            return store
        } catch { try? FileManager.default.removeItem(at: copy); throw error }
    }

    public func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        let i = pieceIndex(at: offset), start = i == 0 ? 0 : ends[i - 1]
        return pieces[i].source.data[pieces[i].range.lowerBound + offset - start]
    }

    public func data(in range: Range<Int>) -> Data {
        let range = clamped(range)
        guard !range.isEmpty else { return Data() }
        var output = Data(); output.reserveCapacity(range.count)
        visit(range) { piece, slice in output.append(piece.source.data[slice]) }
        return output
    }

    public func editedRanges(in range: Range<Int>) -> [Range<Int>] {
        var output: [Range<Int>] = [], offset = clamped(range).lowerBound
        visit(clamped(range)) { piece, slice in
            if piece.edited { output.append(offset..<(offset + slice.count)) }
            offset += slice.count
        }
        return output
    }

    public mutating func replace(_ range: Range<Int>, with data: Data) throws {
        guard range.lowerBound >= 0, range.upperBound <= count else { throw HexaError.message("The edit is outside the file.") }
        guard data.count <= Int.max - (count - range.count) else { throw HexaError.message("The resulting file is too large.") }
        var updated = subpieces(in: 0..<range.lowerBound)
        if !data.isEmpty { updated.append(Piece(source: ByteSource(data: data), range: 0..<data.count, edited: true)) }
        updated += subpieces(in: range.upperBound..<count)
        pieces = []
        for piece in updated {
            if let last = pieces.last, last.source === piece.source, last.range.upperBound == piece.range.lowerBound, last.edited == piece.edited {
                pieces[pieces.count - 1].range = last.range.lowerBound..<piece.range.upperBound
            } else { pieces.append(piece) }
        }
        rebuildIndex()
    }

    /// Streams into a sibling temporary file, synchronizes it, then atomically replaces the destination.
    public func write(to url: URL, range: Range<Int>? = nil, expectedStamp: FileStamp? = nil) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".hexa-\(UUID().uuidString)")
        let descriptor = temp.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temp) }
        let bounds = clamped(range ?? 0..<count)
        var position = bounds.lowerBound
        while position < bounds.upperBound {
            try Task.checkCancellation()
            let end = position + min(4 * 1024 * 1024, bounds.upperBound - position)
            try handle.write(contentsOf: data(in: position..<end)); position = end
        }
        if let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
        }
        try handle.synchronize()
        try handle.close()
        if let expectedStamp, (try? FileStamp(url: url)) != expectedStamp {
            throw HexaError.message("The destination changed while saving. Save As to a different file to keep your edits.")
        }
        let result = temp.withUnsafeFileSystemRepresentation { source in
            url.withUnsafeFileSystemRepresentation { target in Darwin.rename(source!, target!) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Batch replacement builds the new piece table once and shares one replacement buffer.
    public mutating func replaceAll(_ ranges: [Range<Int>], with data: Data) throws {
        var previousEnd = 0, newCount = count
        for range in ranges {
            guard range.lowerBound >= previousEnd, range.upperBound <= count else { throw HexaError.message("Replacement ranges must be sorted, disjoint, and inside the file.") }
            let (size, overflow) = (newCount - range.count).addingReportingOverflow(data.count)
            guard !overflow else { throw HexaError.message("The resulting file is too large.") }
            newCount = size; previousEnd = range.upperBound
        }
        var updated: [Piece] = [], cursor = 0
        let source = ByteSource(data: data)
        for (i, range) in ranges.enumerated() {
            if i % 256 == 0 { try Task.checkCancellation() }
            updated += subpieces(in: cursor..<range.lowerBound)
            if !data.isEmpty { updated.append(Piece(source: source, range: 0..<data.count, edited: true)) }
            cursor = range.upperBound
        }
        updated += subpieces(in: cursor..<count)
        pieces = updated; rebuildIndex()
    }

    private func clamped(_ range: Range<Int>) -> Range<Int> { max(0, min(count, range.lowerBound))..<max(0, min(count, range.upperBound)) }
    private func pieceIndex(at offset: Int) -> Int {
        var low = 0, high = ends.count
        while low < high { let middle = (low + high) / 2; if ends[middle] <= offset { low = middle + 1 } else { high = middle } }
        return low
    }
    private func visit(_ range: Range<Int>, _ body: (Piece, Range<Int>) -> Void) {
        guard !range.isEmpty else { return }
        var i = pieceIndex(at: range.lowerBound), offset = range.lowerBound
        while offset < range.upperBound, i < pieces.count {
            let piece = pieces[i], start = i == 0 ? 0 : ends[i - 1]
            let length = min(ends[i], range.upperBound) - offset
            let sourceStart = piece.range.lowerBound + offset - start
            body(piece, sourceStart..<(sourceStart + length)); offset += length; i += 1
        }
    }
    private func subpieces(in range: Range<Int>) -> [Piece] {
        var result: [Piece] = []
        visit(range) { piece, slice in result.append(Piece(source: piece.source, range: slice, edited: piece.edited)) }
        return result
    }
    private mutating func rebuildIndex() { count = 0; ends = pieces.map { count += $0.count; return count } }
}

public enum HexaError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public struct FileStamp: Equatable, Sendable {
    private let size: UInt64
    private let modified: Date
    private let inode: UInt64
    public init(url: URL) throws {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        size = (a[.size] as? NSNumber)?.uint64Value ?? 0
        modified = a[.modificationDate] as? Date ?? .distantPast
        inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}
