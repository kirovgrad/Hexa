import Foundation

public enum BinaryNodeKind: String, Sendable { case header = "Header", field = "Field", segment = "Segment", section = "Section", directory = "Directory", payload = "Data", group = "Group" }
public struct BinaryNode: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let value: String
    public let range: Range<Int>?
    public let kind: BinaryNodeKind
    public let colorIndex: Int
    public let detail: String
    public let children: [BinaryNode]?
}
public struct BinaryRegion: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let range: Range<Int>
    public let colorIndex: Int
    public let kind: BinaryNodeKind
}
public struct StructureReport: Sendable {
    public let identity: FileIdentity
    public let range: Range<Int>
    public let nodes: [BinaryNode]
    public let regions: [BinaryRegion]
    public let warnings: [String]
    public let architecture: String
    public let declaredEncrypted: Bool
    public var allNodes: [BinaryNode] {
        func flatten(_ nodes: [BinaryNode]) -> [BinaryNode] { nodes.flatMap { [$0] + flatten($0.children ?? []) } }
        return flatten(nodes)
    }
}

/// All reads are relative to a bounded image/slice. No unaligned pointer loads or unchecked file offsets.
struct BinaryReader {
    let store: ByteStore
    let bounds: Range<Int>
    var little = true
    var count: Int { bounds.count }
    func span(_ offset: Int, _ length: Int) throws -> Range<Int> {
        guard offset >= 0, length >= 0, offset <= count, length <= count - offset else {
            throw HexaError.message("Truncated or out-of-range data at relative offset 0x\(String(max(0, offset), radix: 16).uppercased()) (\(length) bytes requested).")
        }
        return (bounds.lowerBound + offset)..<(bounds.lowerBound + offset + length)
    }
    func bytes(_ offset: Int, _ length: Int) throws -> Data { store.data(in: try span(offset, length)) }
    func uint(_ offset: Int, _ width: Int, littleEndian: Bool? = nil) throws -> UInt64 {
        guard [1, 2, 4, 8].contains(width) else { throw HexaError.message("Invalid integer width.") }
        return ByteAnalysis.unsigned(try bytes(offset, width), littleEndian: littleEndian ?? little)!
    }
    func integer(_ offset: Int, _ width: Int) throws -> Int {
        let value = try uint(offset, width)
        guard value <= UInt64(Int.max) else { throw HexaError.message("A declared offset or size exceeds the supported 64-bit file range.") }
        return Int(value)
    }
    func string(_ offset: Int, _ length: Int) throws -> String { String(decoding: try bytes(offset, length).prefix(while: { $0 != 0 }), as: UTF8.self) }
    func cstring(_ offset: Int, end: Int) throws -> String {
        guard offset >= 0, end >= offset, end <= count else { throw HexaError.message("Invalid string table offset.") }
        return try string(offset, min(256, end - offset))
    }
    func table(_ offset: Int, count entries: Int, stride: Int, minimum: Int) throws {
        guard entries >= 0, entries <= 4096 else { throw HexaError.message("Table exceeds the 4,096-entry parsing limit.") }
        guard entries == 0 || stride >= minimum else { throw HexaError.message("Table entry is smaller than its required header.") }
        guard offset >= 0, offset <= count, entries == 0 || entries <= (count - offset) / stride else { throw HexaError.message("A table extends beyond the image.") }
    }
}

public enum BinaryStructure {
    public static func parse(_ store: ByteStore, range: Range<Int>? = nil, format: BinaryFormat = .automatic) throws -> StructureReport {
        let bounds = range ?? 0..<store.count
        guard bounds.lowerBound >= 0, bounds.upperBound <= store.count else { throw HexaError.message("Invalid structure range.") }
        let identity = FileMagic.identify(store, range: bounds)
        let parser = StructureBuilder(reader: BinaryReader(store: store, bounds: bounds), identity: identity)
        do {
            switch format == .automatic ? identity.format : format {
            case .pe: try parser.parsePE()
            case .elf: try parser.parseELF()
            case .machO: try parser.parseMach()
            default: try parser.parseRaw()
            }
        } catch is CancellationError { throw CancellationError() }
        catch { parser.warnings.append(error.localizedDescription) }
        if parser.nodes.isEmpty { parser.nodes = [try parser.node("Unparsed bytes", value: "\(bounds.count.formatted()) bytes", range: bounds, kind: .payload, detail: "The input could not be decoded as the requested format.")] }
        func flatten(_ nodes: [BinaryNode]) -> [BinaryRegion] {
            nodes.flatMap { node in
                let own = node.range.flatMap { $0.isEmpty ? nil : BinaryRegion(id: node.id, name: node.name, range: $0, colorIndex: node.colorIndex, kind: node.kind) }
                return own.map { [$0] + flatten(node.children ?? []) } ?? flatten(node.children ?? [])
            }
        }
        return StructureReport(identity: identity, range: bounds, nodes: parser.nodes, regions: flatten(parser.nodes), warnings: parser.warnings, architecture: parser.architecture, declaredEncrypted: parser.encrypted)
    }
}

final class StructureBuilder {
    var r: BinaryReader
    let identity: FileIdentity
    var nodes: [BinaryNode] = []
    var warnings: [String] = []
    var architecture = "—"
    var encrypted = false
    private var nodeCount = 0
    init(reader: BinaryReader, identity: FileIdentity) { r = reader; self.identity = identity }
    func node(_ name: String, value: String = "", range: Range<Int>? = nil, kind: BinaryNodeKind = .group, detail: String = "", children: [BinaryNode] = []) throws -> BinaryNode {
        try Task.checkCancellation()
        guard nodeCount < 30_000 else { throw HexaError.message("Structure reached the 30,000-field display limit.") }
        nodeCount += 1
        return BinaryNode(name: name, value: value, range: range, kind: kind, colorIndex: nodeCount % 8, detail: detail, children: children.isEmpty ? nil : children)
    }
    func field(_ name: String, _ offset: Int, _ width: Int, value: String? = nil, detail: String = "") throws -> BinaryNode {
        let v = try r.uint(offset, width)
        return try node(name, value: value ?? "\(v) · 0x\(String(v, radix: 16).uppercased())", range: r.span(offset, width), kind: .field, detail: detail)
    }
    func textField(_ name: String, _ offset: Int, _ width: Int) throws -> BinaryNode {
        try node(name, value: r.string(offset, width), range: r.span(offset, width), kind: .field)
    }
    func fields(_ base: Int, _ specs: [(String, Int, Int)]) throws -> [BinaryNode] { try specs.map { try field($0.0, base + $0.1, $0.2) } }
    func region(_ name: String, offset: Int, size: Int, kind: BinaryNodeKind = .payload, value: String = "", detail: String = "", children: [BinaryNode] = []) throws -> BinaryNode {
        var range: Range<Int>?
        do { range = try r.span(offset, size) } catch { warnings.append("\(name): \(error.localizedDescription)") }
        return try node(name, value: value.isEmpty ? "\(size.formatted()) bytes" : value, range: range, kind: kind, detail: detail, children: children)
    }
    func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16).uppercased() }
    func parseRaw() throws {
        var interpretations: [BinaryNode] = []
        for width in [1, 2, 4, 8] where r.count >= width {
            let data = try r.bytes(0, width)
            interpretations.append(try node("UInt\(width * 8)", value: "LE \(ByteAnalysis.unsigned(data, littleEndian: true)!) · BE \(ByteAnalysis.unsigned(data, littleEndian: false)!)", range: r.span(0, width), kind: .field, detail: "An interpretation, not a detected format field."))
        }
        if r.count > 0 { interpretations.append(try node("Text prefix", value: String(decoding: try r.bytes(0, min(128, r.count)), as: UTF8.self), range: r.span(0, min(128, r.count)), kind: .field)) }
        nodes.append(try node("Interpretations at start", value: identity.name, kind: .header, detail: "No schema is assumed for unknown bytes.", children: interpretations))
        let stride = max(16, r.count / 128 + (r.count % 128 == 0 ? 0 : 1))
        var chunks: [BinaryNode] = [], offset = 0
        while offset < r.count {
            let size = min(stride, r.count - offset)
            chunks.append(try node("Bytes \(hex(UInt64(r.bounds.lowerBound + offset)))", value: ByteFormatting.hex(try r.bytes(offset, min(16, size))) + (size > 16 ? " …" : ""), range: r.span(offset, size), kind: .payload, detail: "\(size.formatted()) raw bytes. Select to inspect or edit in the byte grid."))
            offset += size
        }
        nodes.append(try node("Raw data", value: "\(r.count.formatted()) bytes", range: r.bounds, kind: .group, children: chunks))
    }
}
