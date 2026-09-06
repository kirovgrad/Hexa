import Foundation

extension StructureBuilder {
    func parseELF() throws {
        guard try r.bytes(0,4) == Data([0x7f,0x45,0x4c,0x46]) else { throw HexaError.message("Missing ELF signature.") }
        let elfClass = try r.uint(4,1), encoding = try r.uint(5,1)
        guard [1,2].contains(elfClass), [1,2].contains(encoding) else { throw HexaError.message("Unsupported ELF class or byte-order encoding.") }
        let is64 = elfClass == 2, width = is64 ? 8 : 4, headerSize = is64 ? 64 : 52, sizes = is64 ? 52 : 40
        r.little = encoding == 1
        _ = try r.span(0,headerSize)
        let machine = try r.uint(18,2)
        architecture = [UInt64(3):"x86",8:"MIPS",20:"PowerPC",21:"PowerPC64",40:"ARM",62:"x86-64",183:"AArch64",243:"RISC-V",247:"BPF"][machine] ?? hex(machine)
        let info = "\(is64 ? "64" : "32")-bit · \(r.little ? "little" : "big") endian · \(architecture)"
        let fields = try self.fields(0, [("Magic",0,4),("Class",4,1),("Data encoding",5,1),("Identification version",6,1),("OS ABI",7,1),("ABI version",8,1),("Object type",16,2),("Machine",18,2),("Version",20,4),("Entry virtual address",24,width),("Program header file offset",24+width,width),("Section header file offset",24+width*2,width),("Flags",24+width*3,4),("Header size",sizes,2),("Program entry size",sizes+2,2),("Program entry count",sizes+4,2),("Section entry size",sizes+6,2),("Section entry count",sizes+8,2),("Section-name string table index",sizes+10,2)])
        nodes.append(try node("ELF header", value: info, range: r.span(0,headerSize), kind: .header, children: fields))
        if try r.integer(sizes,2) < headerSize { warnings.append("ELF e_ehsize is smaller than the required header.") }
        let phoff = try r.integer(24+width,width), shoff = try r.integer(24+width*2,width)
        let phsize = try r.integer(sizes+2,2), shsize = try r.integer(sizes+6,2)
        var phcount = try r.integer(sizes+4,2), shcount = try r.integer(sizes+8,2), strIndex = try r.integer(sizes+10,2)
        let shMinimum = is64 ? 64 : 40
        if shoff != 0, shcount == 0 || strIndex == 0xffff || phcount == 0xffff {
            try r.table(shoff, count: 1, stride: shsize, minimum: shMinimum)
            if shcount == 0 { shcount = try r.integer(shoff + (is64 ? 32 : 20),width) }
            if strIndex == 0xffff { strIndex = try r.integer(shoff + (is64 ? 40 : 24),4) }
            if phcount == 0xffff { phcount = try r.integer(shoff + (is64 ? 44 : 28),4) }
        }
        if phcount > 0 {
            try r.table(phoff, count: phcount, stride: phsize, minimum: is64 ? 56 : 32)
            var programs: [BinaryNode] = []
            for index in 0..<phcount {
                let p = phoff + index * phsize, type = try r.uint(p,4)
                let offset = try r.integer(p + (is64 ? 8 : 4),width), size = try r.integer(p + (is64 ? 32 : 16),width)
                let virtual = try r.uint(p + (is64 ? 16 : 8),width), memory = try r.uint(p + (is64 ? 40 : 20),width), flags = try r.uint(p + (is64 ? 4 : 24),4)
                let name = [UInt64(0):"NULL",1:"LOAD",2:"DYNAMIC",3:"INTERP",4:"NOTE",5:"SHLIB",6:"PHDR",7:"TLS",0x6474e550:"GNU_EH_FRAME",0x6474e551:"GNU_STACK",0x6474e552:"GNU_RELRO",0x6474e553:"GNU_PROPERTY"][type] ?? hex(type)
                let detail = "VA \(hex(virtual)) · \(memory.formatted()) memory bytes · " + [flags & 4 != 0 ? "R" : "−",flags & 2 != 0 ? "W" : "−",flags & 1 != 0 ? "X" : "−"].joined()
                let specs: [(String,Int,Int)] = is64 ? [("Type",0,4),("Flags",4,4),("File offset",8,8),("Virtual address",16,8),("Physical address",24,8),("File size",32,8),("Memory size",40,8),("Alignment",48,8)] : [("Type",0,4),("File offset",4,4),("Virtual address",8,4),("Physical address",12,4),("File size",16,4),("Memory size",20,4),("Flags",24,4),("Alignment",28,4)]
                var children = try self.fields(p,specs)
                if type != 0, size > 0 { children.append(try region("\(name) bytes", offset: offset, size: size, kind: .payload, detail: detail)) }
                programs.append(try node("\(index) · \(name)", value: detail, range: r.span(p,phsize), kind: .segment, children: children))
            }
            nodes.append(try node("Program headers / segments", value: "\(phcount) entries", range: r.span(phoff,phcount*phsize), kind: .group, children: programs))
        }
        if shcount > 0 {
            try r.table(shoff, count: shcount, stride: shsize, minimum: shMinimum)
            var stringBounds: Range<Int>?
            if strIndex > 0, strIndex < shcount {
                let s = shoff + strIndex * shsize
                if try r.uint(s+4,4) == 3 {
                    let offset = try r.integer(s + (is64 ? 24 : 16),width), size = try r.integer(s + (is64 ? 32 : 20),width)
                    if let checked = try? r.span(offset,size) { stringBounds = (checked.lowerBound-r.bounds.lowerBound)..<(checked.upperBound-r.bounds.lowerBound) }
                    else { warnings.append("Section-name string table is outside the image.") }
                } else { warnings.append("The section-name index does not identify a string table.") }
            } else if strIndex != 0 { warnings.append("Invalid section-name string table index.") }
            var sections: [BinaryNode] = []
            for index in 0..<shcount {
                let s = shoff + index * shsize, nameOffset = try r.integer(s,4), type = try r.uint(s+4,4)
                let fileOffset = try r.integer(s + (is64 ? 24 : 16),width), size = try r.integer(s + (is64 ? 32 : 20),width)
                var name = "Section \(index)"
                if let strings = stringBounds, nameOffset < strings.count { let candidate = try r.cstring(strings.lowerBound + nameOffset, end: strings.upperBound); if !candidate.isEmpty { name = candidate } }
                let typeName = [UInt64(0):"NULL",1:"PROGBITS",2:"SYMTAB",3:"STRTAB",4:"RELA",5:"HASH",6:"DYNAMIC",7:"NOTE",8:"NOBITS",9:"REL",11:"DYNSYM",14:"INIT_ARRAY",15:"FINI_ARRAY",16:"PREINIT_ARRAY",17:"GROUP",18:"SYMTAB_SHNDX",0x6ffffff6:"GNU_HASH",0x6fffffff:"GNU_VERSYM"][type] ?? hex(type)
                let specs: [(String,Int,Int)] = is64 ? [("Name string offset",0,4),("Type",4,4),("Flags",8,8),("Virtual address",16,8),("File offset",24,8),("Size",32,8),("Link",40,4),("Info",44,4),("Alignment",48,8),("Entry size",56,8)] : [("Name string offset",0,4),("Type",4,4),("Flags",8,4),("Virtual address",12,4),("File offset",16,4),("Size",20,4),("Link",24,4),("Info",28,4),("Alignment",32,4),("Entry size",36,4)]
                var children = try self.fields(s,specs)
                if type != 0, type != 8, size > 0 { children.append(try region("\(name) bytes", offset: fileOffset, size: size, kind: .payload)) }
                let detail = type == 8 ? "NOBITS · \(size.formatted()) memory bytes, no bytes in this file" : "\(typeName) · \(size.formatted()) bytes"
                sections.append(try node(name, value: detail, range: r.span(s,shsize), kind: .section, detail: detail, children: children))
            }
            nodes.append(try node("Section headers", value: "\(shcount) entries", range: r.span(shoff,shcount*shsize), kind: .group, children: sections))
        }
    }
}
