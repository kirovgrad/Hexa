import Foundation

extension StructureBuilder {
    func parsePE() throws {
        r.little = true
        guard try r.bytes(0, 2) == Data("MZ".utf8) else { throw HexaError.message("Missing DOS MZ signature.") }
        _ = try r.span(0, 64)
        let dosFields = try fields(0, [("Magic · MZ",0,2),("Last page bytes",2,2),("Pages",4,2),("Relocations",6,2),("Header paragraphs",8,2),("Minimum allocation",10,2),("Maximum allocation",12,2),("Initial SS",14,2),("Initial SP",16,2),("Checksum",18,2),("Initial IP",20,2),("Initial CS",22,2),("Relocation table offset",24,2),("Overlay number",26,2),("OEM ID",36,2),("OEM info",38,2),("PE header offset · e_lfanew",60,4)])
        nodes.append(try node("DOS header", value: "IMAGE_DOS_HEADER", range: r.span(0, 64), kind: .header, children: dosFields))
        let pe = try r.integer(60, 4)
        if pe > 64 { nodes.append(try region("DOS stub", offset: 64, size: min(pe, r.count) - 64)) }
        guard try r.bytes(pe, 4) == Data([0x50,0x45,0,0]) else { throw HexaError.message("MZ data is present, but e_lfanew does not point to a PE signature. This may be a DOS executable.") }
        nodes.append(try node("PE signature", value: "PE\\0\\0", range: r.span(pe, 4), kind: .header))
        let coff = pe + 4
        _ = try r.span(coff, 20)
        let machine = try r.uint(coff, 2), sectionCount = try r.integer(coff + 2, 2)
        architecture = [UInt64(0x14c):"x86",0x8664:"x86-64",0x1c0:"ARM",0x1c4:"ARM Thumb-2",0xaa64:"ARM64",0xa641:"ARM64EC",0x200:"IA-64",0x5032:"RISC-V 32",0x5064:"RISC-V 64"][machine] ?? hex(machine)
        var coffFields = try fields(coff, [("Number of sections",2,2),("Timestamp",4,4),("Symbol table file offset",8,4),("Symbol count",12,4),("Optional header size",16,2),("Characteristics",18,2)])
        coffFields.insert(try field("Machine", coff, 2, value: architecture + " · " + hex(machine)), at: 0)
        nodes.append(try node("COFF header", value: architecture, range: r.span(coff, 20), kind: .header, children: coffFields))
        let optionalSize = try r.integer(coff + 16, 2), optional = coff + 20
        _ = try r.span(optional, optionalSize)
        var directoryOffset = 0, directoryCount = 0, sizeOfHeaders = 0, entryRVA: Int?
        if optionalSize > 0 {
            let magic = try r.uint(optional, 2), is64 = magic == 0x20b
            guard magic == 0x10b || is64 else { throw HexaError.message("Unsupported optional-header magic \(hex(magic)); expected PE32 or PE32+.") }
            let minimum = is64 ? 112 : 96
            guard optionalSize >= minimum else { throw HexaError.message("Optional header is shorter than the PE32/PE32+ fixed fields.") }
            var specs: [(String,Int,Int)] = [("Magic",0,2),("Linker major",2,1),("Linker minor",3,1),("Code size",4,4),("Initialized data size",8,4),("Uninitialized data size",12,4),("Entry point RVA",16,4),("Code base RVA",20,4)]
            if !is64 { specs.append(("Data base RVA",24,4)) }
            specs += [("Image base",is64 ? 24 : 28,is64 ? 8 : 4),("Section alignment",32,4),("File alignment",36,4),("OS major",40,2),("OS minor",42,2),("Image major",44,2),("Image minor",46,2),("Subsystem major",48,2),("Subsystem minor",50,2),("Win32 version",52,4),("Image memory size",56,4),("Headers file size",60,4),("Checksum",64,4),("Subsystem",68,2),("DLL characteristics",70,2),("Stack reserve",72,is64 ? 8 : 4),("Stack commit",is64 ? 80 : 76,is64 ? 8 : 4),("Heap reserve",is64 ? 88 : 80,is64 ? 8 : 4),("Heap commit",is64 ? 96 : 84,is64 ? 8 : 4),("Loader flags",is64 ? 104 : 88,4),("Data directory count",is64 ? 108 : 92,4)]
            nodes.append(try node("Optional header · \(is64 ? "PE32+" : "PE32")", value: is64 ? "64-bit image" : "32-bit image", range: r.span(optional, minimum), kind: .header, children: fields(optional, specs)))
            directoryOffset = optional + minimum
            let declared = try r.integer(optional + minimum - 4, 4)
            directoryCount = min(16, min(declared, (optionalSize - minimum) / 8))
            if declared > (optionalSize - minimum) / 8 { warnings.append("Declared data-directory count exceeds the optional header.") }
            if declared > 16 { warnings.append("Only the 16 standard PE data directories are decoded.") }
            sizeOfHeaders = try r.integer(optional + 60, 4); entryRVA = try r.integer(optional + 16, 4)
        }
        let table = optional + optionalSize
        try r.table(table, count: sectionCount, stride: 40, minimum: 40)
        struct SectionMap { let rva: Int; let virtualSize: Int; let fileOffset: Int; let fileSize: Int }
        var maps: [SectionMap] = [], sections: [BinaryNode] = []
        for index in 0..<sectionCount {
            let s = table + index * 40, name = try r.string(s, 8)
            let virtualSize = try r.integer(s+8,4), rva = try r.integer(s+12,4), size = try r.integer(s+16,4), offset = try r.integer(s+20,4), flags = try r.uint(s+36,4)
            maps.append(SectionMap(rva: rva, virtualSize: virtualSize, fileOffset: offset, fileSize: size))
            var detail = "RVA \(hex(UInt64(rva))) · \(virtualSize.formatted()) bytes in memory · "
            detail += [flags & 0x40000000 != 0 ? "R" : "−", flags & 0x80000000 != 0 ? "W" : "−", flags & 0x20000000 != 0 ? "X" : "−"].joined()
            var children = [try textField("Name",s,8)] + (try fields(s, [("Virtual size",8,4),("Virtual address · RVA",12,4),("Raw size",16,4),("Raw file offset",20,4),("Relocations file offset",24,4),("Line numbers file offset",28,4),("Relocation count",32,2),("Line number count",34,2),("Characteristics",36,4)]))
            if size > 0 { children.append(try region("\(name) bytes", offset: offset, size: size, kind: .payload, detail: detail)) }
            sections.append(try node(name.isEmpty ? "Section \(index)" : name, value: detail, range: r.span(s,40), kind: .section, detail: size == 0 ? "No raw bytes; memory-only or empty section." : detail, children: children))
        }
        nodes.append(try node("Section table", value: "\(sectionCount) sections", range: r.span(table, sectionCount * 40), kind: .group, children: sections))
        func fileOffset(forRVA address: Int, size: Int) -> Int? {
            if address < sizeOfHeaders, address <= r.count, size <= min(sizeOfHeaders, r.count) - address { return address }
            for section in maps where address >= section.rva {
                let delta = address - section.rva
                if delta < section.fileSize, size <= section.fileSize - delta { return section.fileOffset + delta }
            }
            return nil
        }
        if directoryCount > 0 {
            let names = ["Exports", "Imports", "Resources", "Exceptions", "Certificates (file offset)", "Base relocations", "Debug", "Architecture", "Global pointer", "TLS", "Load configuration", "Bound imports", "Import address table", "Delay imports", "CLR runtime", "Reserved"]
            var directories: [BinaryNode] = []
            for index in 0..<directoryCount {
                let d = directoryOffset + index * 8, address = try r.integer(d,4), size = try r.integer(d+4,4)
                var children = try fields(d, [(index == 4 ? "File offset" : "RVA",0,4),("Size",4,4)])
                if size > 0, address > 0 {
                    if let offset = index == 4 ? address : fileOffset(forRVA: address, size: size) {
                        children.append(try region("\(names[index]) data", offset: offset, size: size, kind: .directory))
                    } else { warnings.append("\(names[index]) RVA has no complete file-backed range.") }
                }
                directories.append(try node(names[index], value: size == 0 ? "Absent" : "\(size.formatted()) bytes", range: r.span(d,8), kind: .directory, children: children))
            }
            nodes.append(try node("Data directories", value: "\(directoryCount) entries", kind: .group, children: directories))
        }
        if let entryRVA, entryRVA > 0, let offset = fileOffset(forRVA: entryRVA, size: 1) { nodes.append(try region("Entry point", offset: offset, size: 1, value: "RVA " + hex(UInt64(entryRVA)))) }
    }
}
