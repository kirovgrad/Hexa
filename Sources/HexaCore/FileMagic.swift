import Foundation

public enum BinaryFormat: String, CaseIterable, Sendable { case automatic = "Automatic", pe = "PE", elf = "ELF", machO = "Mach-O", raw = "Raw bytes" }
public enum FileCategory: String, Sendable { case executable = "Executable", archive = "Archive", compressed = "Compressed", encrypted = "Encrypted container", image = "Image", media = "Media", document = "Document", database = "Database", font = "Font", text = "Text", binary = "Binary" }

public struct MagicRule: Identifiable, Sendable {
    public var id: String { name + String(offset) }
    public let name: String
    public let mime: String
    public let category: FileCategory
    public let offset: Int
    public let bytes: [UInt8]
    public let format: BinaryFormat
    init(_ name: String, _ mime: String, _ category: FileCategory, _ hex: String, offset: Int = 0, format: BinaryFormat = .raw) {
        self.name = name; self.mime = mime; self.category = category; self.offset = offset
        self.bytes = (try? BytePattern(hex: hex, wildcards: false).values) ?? []; self.format = format
    }
}

public struct FileIdentity: Sendable {
    public let name: String
    public let mime: String
    public let category: FileCategory
    public let format: BinaryFormat
    public let evidence: String
    public let signatureRange: Range<Int>?
}

/// Local, content-based signature/MIME database. Specific container subtypes are resolved below.
public enum FileMagic {
    public static let rules: [MagicRule] = [
        .init("ELF executable", "application/x-elf", .executable, "7F454C46", format: .elf),
        .init("DOS / PE executable", "application/vnd.microsoft.portable-executable", .executable, "4D5A", format: .pe),
        .init("Mach-O 32-bit · big endian", "application/x-mach-binary", .executable, "FEEDFACE", format: .machO),
        .init("Mach-O 32-bit · little endian", "application/x-mach-binary", .executable, "CEFAEDFE", format: .machO),
        .init("Mach-O 64-bit · big endian", "application/x-mach-binary", .executable, "FEEDFACF", format: .machO),
        .init("Mach-O 64-bit · little endian", "application/x-mach-binary", .executable, "CFFAEDFE", format: .machO),
        .init("Universal Mach-O", "application/x-mach-binary", .executable, "CAFEBABE", format: .machO),
        .init("Universal Mach-O · swapped", "application/x-mach-binary", .executable, "BEBAFECA", format: .machO),
        .init("Universal Mach-O 64-bit", "application/x-mach-binary", .executable, "CAFEBABF", format: .machO),
        .init("Universal Mach-O 64-bit · swapped", "application/x-mach-binary", .executable, "BFBAFECA", format: .machO),
        .init("WebAssembly", "application/wasm", .executable, "0061736D"),
        .init("Dalvik DEX", "application/vnd.android.dex", .executable, "6465780A"),
        .init("LLVM bitcode", "application/x-llvm-bitcode", .executable, "4243C0DE"),
        .init("Unix archive", "application/x-archive", .archive, "213C617263683E0A"),
        .init("ZIP archive", "application/zip", .archive, "504B0304"),
        .init("ZIP empty archive", "application/zip", .archive, "504B0506"),
        .init("ZIP split archive", "application/zip", .archive, "504B0708"),
        .init("RAR 5 archive", "application/vnd.rar", .archive, "526172211A070100"),
        .init("RAR archive", "application/vnd.rar", .archive, "526172211A0700"),
        .init("7-Zip archive", "application/x-7z-compressed", .archive, "377ABCAF271C"),
        .init("Gzip", "application/gzip", .compressed, "1F8B08"),
        .init("Bzip2", "application/x-bzip2", .compressed, "425A68"),
        .init("XZ", "application/x-xz", .compressed, "FD377A585A00"),
        .init("Zstandard", "application/zstd", .compressed, "28B52FFD"),
        .init("LZ4 frame", "application/x-lz4", .compressed, "04224D18"),
        .init("Unix compress", "application/x-compress", .compressed, "1F9D"),
        .init("TAR archive", "application/x-tar", .archive, "7573746172", offset: 257),
        .init("CAB archive", "application/vnd.ms-cab-compressed", .archive, "4D534346"),
        .init("XAR archive", "application/x-xar", .archive, "78617221"),
        .init("LUKS volume", "application/x-luks", .encrypted, "4C554B53BABE"),
        .init("OpenSSL salted envelope", "application/octet-stream", .encrypted, "53616C7465645F5F"),
        .init("age encrypted file", "application/octet-stream", .encrypted, "6167652D656E6372797074696F6E2E6F72672F7631"),
        .init("Armored PGP message", "application/pgp-encrypted", .encrypted, "2D2D2D2D2D424547494E20504750204D4553534147452D2D2D2D2D"),
        .init("PNG image", "image/png", .image, "89504E470D0A1A0A"),
        .init("JPEG image", "image/jpeg", .image, "FFD8FF"),
        .init("GIF 89a", "image/gif", .image, "474946383961"),
        .init("GIF 87a", "image/gif", .image, "474946383761"),
        .init("TIFF · little endian", "image/tiff", .image, "49492A00"),
        .init("TIFF · big endian", "image/tiff", .image, "4D4D002A"),
        .init("BigTIFF", "image/tiff", .image, "49492B00"),
        .init("Bitmap image", "image/bmp", .image, "424D"),
        .init("Windows icon", "image/vnd.microsoft.icon", .image, "00000100"),
        .init("Apple icon", "image/icns", .image, "69636E73"),
        .init("Photoshop document", "image/vnd.adobe.photoshop", .image, "38425053"),
        .init("OpenEXR", "image/x-exr", .image, "762F3101"),
        .init("JPEG XL", "image/jxl", .image, "0000000C4A584C200D0A870A"),
        .init("QOI image", "image/qoi", .image, "716F6966"),
        .init("PDF document", "application/pdf", .document, "255044462D"),
        .init("PostScript", "application/postscript", .document, "25215053"),
        .init("RTF document", "application/rtf", .document, "7B5C727466"),
        .init("OLE compound document", "application/x-ole-storage", .document, "D0CF11E0A1B11AE1"),
        .init("Binary property list", "application/x-plist", .document, "62706C6973743030"),
        .init("SQLite 3 database", "application/vnd.sqlite3", .database, "53514C69746520666F726D6174203300"),
        .init("Parquet data", "application/vnd.apache.parquet", .database, "50415231"),
        .init("Apache Avro", "application/avro", .database, "4F626A01"),
        .init("HDF5 data", "application/x-hdf5", .database, "894844460D0A1A0A"),
        .init("FLAC audio", "audio/flac", .media, "664C6143"),
        .init("Ogg container", "application/ogg", .media, "4F676753"),
        .init("MP3 with ID3 tag", "audio/mpeg", .media, "494433"),
        .init("MIDI", "audio/midi", .media, "4D546864"),
        .init("Matroska / WebM container", "video/x-matroska", .media, "1A45DFA3"),
        .init("Flash video", "video/x-flv", .media, "464C5601"),
        .init("WOFF font", "font/woff", .font, "774F4646"),
        .init("WOFF2 font", "font/woff2", .font, "774F4632"),
        .init("OpenType font", "font/otf", .font, "4F54544F"),
        .init("TrueType collection", "font/collection", .font, "74746366"),
        .init("TrueType font", "font/ttf", .font, "0001000000"),
        .init("PCAP capture", "application/vnd.tcpdump.pcap", .binary, "D4C3B2A1"),
        .init("PCAP capture · big endian", "application/vnd.tcpdump.pcap", .binary, "A1B2C3D4"),
        .init("PCAPNG capture", "application/x-pcapng", .binary, "0A0D0D0A"),
        .init("Java serialization", "application/x-java-serialized-object", .binary, "ACED0005")
    ]

    public static func identify(_ store: ByteStore, range: Range<Int>? = nil) -> FileIdentity {
        let bounds = range ?? 0..<store.count
        guard bounds.lowerBound >= 0, bounds.upperBound <= store.count else { return unknown("Invalid range") }
        let prefix = store.data(in: bounds.lowerBound..<(bounds.lowerBound + min(65_536, bounds.count)))
        func result(_ name: String, _ mime: String, _ category: FileCategory, _ format: BinaryFormat = .raw, offset: Int = 0, length: Int = 4, evidence: String = "Magic signature") -> FileIdentity {
            FileIdentity(name: name, mime: mime, category: category, format: format, evidence: evidence,
                         signatureRange: (offset <= bounds.count && length <= bounds.count - offset) ? (bounds.lowerBound + offset)..<(bounds.lowerBound + offset + length) : nil)
        }
        if prefix.starts(with: [0xCA, 0xFE, 0xBA, 0xBE]), prefix.count >= 8 {
            let version = ByteAnalysis.unsigned(prefix.subdata(in: 6..<8), littleEndian: false) ?? 0
            let count = ByteAnalysis.unsigned(prefix.subdata(in: 4..<8), littleEndian: false) ?? 0
            // Java major versions share the FAT magic. Check a plausible first slice before treating
            // a large architecture count as a class version (e.g. Java 17's major version is 61).
            var plausibleFat = false
            if count > 0, count <= 4096, prefix.count >= 28 {
                let offset = ByteAnalysis.unsigned(prefix.subdata(in: 16..<20), littleEndian: false) ?? 0
                let size = ByteAnalysis.unsigned(prefix.subdata(in: 20..<24), littleEndian: false) ?? 0
                plausibleFat = offset >= 8 + count * 20 && offset <= UInt64(bounds.count) && size > 0 && size <= UInt64(bounds.count) - offset
            }
            if count > 32, version >= 45, !plausibleFat { return result("Java class file", "application/java-vm", .executable, length: 8) }
        }
        if prefix.count >= 12, prefix.prefix(4) == Data("RIFF".utf8) {
            switch String(decoding: prefix[8..<12], as: UTF8.self) {
            case "WEBP": return result("WebP image", "image/webp", .image, length: 12)
            case "WAVE": return result("WAVE audio", "audio/wav", .media, length: 12)
            case "AVI ": return result("AVI video", "video/x-msvideo", .media, length: 12)
            default: return result("RIFF container", "application/octet-stream", .media, length: 12)
            }
        }
        if prefix.count >= 12, prefix[4..<8] == Data("ftyp".utf8) {
            let brand = String(decoding: prefix[8..<12], as: UTF8.self)
            if ["avif", "avis"].contains(brand) { return result("AVIF image", "image/avif", .image, length: 12) }
            if ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand) { return result("HEIF image", "image/heif", .image, length: 12) }
            return result(brand == "qt  " ? "QuickTime movie" : "ISO base media / MP4", brand == "qt  " ? "video/quicktime" : "video/mp4", .media, length: 12)
        }
        for rule in rules where !rule.bytes.isEmpty && rule.offset <= prefix.count && rule.bytes.count <= prefix.count - rule.offset {
            if prefix[rule.offset..<(rule.offset + rule.bytes.count)].elementsEqual(rule.bytes) {
                return result(rule.name, rule.mime, rule.category, rule.format, offset: rule.offset, length: rule.bytes.count)
            }
        }
        if bounds.isEmpty { return unknown("Empty input") }
        if let text = String(data: prefix, encoding: .utf8), !prefix.contains(0) {
            let controls = prefix.filter { $0 < 32 && ![9, 10, 13].contains($0) }.count
            if controls == 0 {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("<?xml") { return result("XML document", "application/xml", .text, length: 0, evidence: "UTF-8 prefix heuristic") }
                if bounds.count <= prefix.count, (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")), (try? JSONSerialization.jsonObject(with: prefix)) != nil {
                    return result("JSON document", "application/json", .text, length: 0, evidence: "Validated JSON")
                }
                return result("UTF-8 text", "text/plain", .text, length: 0, evidence: "UTF-8 prefix heuristic · first 64 KiB")
            }
        }
        return unknown("No known signature; raw interpretation available")
    }
    private static func unknown(_ evidence: String) -> FileIdentity { FileIdentity(name: "Unidentified data", mime: "application/octet-stream", category: .binary, format: .raw, evidence: evidence, signatureRange: nil) }
}
