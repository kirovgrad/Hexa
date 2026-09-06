import Foundation

public enum ByteClass: String, CaseIterable, Identifiable, Sendable {
    case zero = "Zero", whitespace = "Whitespace", printable = "Printable", control = "Control", high = "High bytes", ff = "FF"
    public var id: String { rawValue }
    public var index: Int { Self.allCases.firstIndex(of:self)! }
    public static func classify(_ byte: UInt8) -> Int {
        if byte == 0 { return 0 }; if byte == 255 { return 5 }
        if [9,10,11,12,13,32].contains(byte) { return 1 }
        if byte >= 33 && byte <= 126 { return 2 }
        return byte <= 31 || byte == 127 ? 3:4
    }
    public var definition: String {
        switch self { case .zero:return "00";case .whitespace:return "09–0D and 20";case .printable:return "21–7E";case .control:return "01–08, 0E–1F, 7F";case .high:return "80–FE";case .ff:return "FF" }
    }
}
public struct EntropyWindow: Identifiable, Sendable {
    public var id: Int { range.lowerBound }
    public let range: Range<Int>
    public let entropy: Double
    public let byteTypes: [Int]
}
public struct ContentAssessment: Sendable {
    public let title: String
    public let detail: String
    public let evidence: String
}
public struct AnalysisSignals: Sendable {
    public let identity: FileIdentity
    public let windows: [EntropyWindow]
    public let windowSize: Int
    public let byteTypes: [Int]
    public let digrams: [Int]
    /// Row is byte value; column is its position bin. Count-based, not sampled bytes.
    public let layers: [Int]
    public let layerCount: Int
    public let layerSize: Int
    public let highestEntropy: Double
    public let averageEntropy: Double
    public let cryptoMatches: [CryptoMatch]
    public let cryptoTruncated: Bool
    public let assessment: ContentAssessment
}

struct SignalAccumulator {
    let bounds: Range<Int>
    let windowSize: Int
    let layerSize: Int
    let layerCount: Int
    private var windowHistogram = Array(repeating:0,count:256)
    private var windowTypes = Array(repeating:0,count:6)
    private var windowStart: Int
    private var windowCount = 0
    private var offset: Int
    private var previous: UInt8?
    private var windows: [EntropyWindow] = []
    private var types = Array(repeating:0,count:6)
    private var digrams = Array(repeating:0,count:65_536)
    private var layers: [Int]
    private var crypto = CryptoScanner()
    private static let classes = (0...255).map { ByteClass.classify(UInt8($0)) }
    init(range: Range<Int>) {
        bounds = range; windowStart = range.lowerBound; offset = range.lowerBound
        let perWindow = range.count / 1024 + (range.count % 1024 == 0 ? 0:1)
        // At most 1,024 windows, at least 4 KiB each. No overflow-prone rounded addition.
        windowSize = max(4096,perWindow)
        layerSize = max(1,range.count / 256 + (range.count % 256 == 0 ? 0:1))
        layerCount = max(1,range.count / layerSize + (range.count % layerSize == 0 ? 0:1))
        layers = Array(repeating:0,count:256*layerCount)
    }
    mutating func consume(_ data: Data, final: Bool) throws {
        try crypto.consume(data,offset:offset,final:final)
        for byte in data {
            if offset & 0xffff == 0 { try Task.checkCancellation() }
            let value = Int(byte), type = Self.classes[value]
            windowHistogram[value] += 1; windowTypes[type] += 1; types[type] += 1
            layers[value*layerCount + min(layerCount-1,(offset-bounds.lowerBound)/layerSize)] += 1
            if let previous { digrams[Int(previous)*256+value] += 1 }
            previous = byte; offset += 1; windowCount += 1
            if windowCount == windowSize { flushWindow() }
        }
        if final { flushWindow() }
    }
    private mutating func flushWindow() {
        guard windowCount > 0 else { return }
        let entropy = windowHistogram.filter { $0 > 0 }.reduce(0.0) { sum,n in let p = Double(n)/Double(windowCount); return sum-p*log2(p) }
        windows.append(EntropyWindow(range:windowStart..<offset,entropy:entropy,byteTypes:windowTypes))
        windowStart = offset; windowCount = 0; windowHistogram = Array(repeating:0,count:256); windowTypes = Array(repeating:0,count:6)
    }
    func finish(identity: FileIdentity) -> AnalysisSignals {
        let average = bounds.isEmpty ? 0 : windows.reduce(0.0) { $0 + $1.entropy*Double($1.range.count) }/Double(bounds.count)
        let highest = windows.map(\.entropy).max() ?? 0
        let assessment: ContentAssessment
        switch identity.category {
        case .encrypted: assessment = ContentAssessment(title:"Encryption container identified",detail:"The magic bytes identify an encrypted envelope. This does not validate or decrypt its payload.",evidence:identity.name)
        case .compressed: assessment = ContentAssessment(title:"Compression format identified",detail:"A recognized compression header is present. Integrity and decompression have not been checked.",evidence:identity.name)
        case .archive: assessment = ContentAssessment(title:"Archive container identified",detail:"Archive entries may be compressed, stored, or encrypted. The container signature alone does not decide which.",evidence:identity.name)
        default:
            if bounds.count < 4096 { assessment = ContentAssessment(title:"Too little data to classify",detail:"At least 4 KiB is needed for the entropy heuristic. Short-window estimates are biased downward.",evidence:"\(bounds.count.formatted()) analyzed bytes") }
            else if average >= 7.5 {
                assessment = ContentAssessment(title:"Possibly compressed or encrypted",detail:"High entropy is also produced by random, multimedia, and packed data. Entropy cannot distinguish encryption from compression.",evidence:String(format:"Average window entropy %.3f / 8",average))
            } else if identity.category == .text { assessment = ContentAssessment(title:"Text-like content",detail:"The prefix decodes as text and the average window entropy is below the high-entropy threshold.",evidence:identity.evidence) }
            else { assessment = ContentAssessment(title:"Structured or mixed content",detail:highest >= 7.5 ? "Some regions have high entropy; inspect the graph to locate them. This is not proof of encryption." : "Window entropy stays below the high-entropy threshold. This does not rule out compressed or encrypted subregions.",evidence:String(format:"Average %.3f · highest %.3f",average,highest)) }
        }
        return AnalysisSignals(identity:identity,windows:windows,windowSize:windowSize,byteTypes:types,digrams:digrams,layers:layers,layerCount:layerCount,layerSize:layerSize,highestEntropy:highest,averageEntropy:average,cryptoMatches:crypto.matches,cryptoTruncated:crypto.truncated,assessment:assessment)
    }
}
