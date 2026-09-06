import Foundation

extension StructureBuilder {
    func parseMach() throws {
        let magic = try r.uint(0,4,littleEndian:false)
        if [0xcafebabe,0xbebafeca,0xcafebabf,0xbfbafeca].contains(magic) { try parseFat(magic); return }
        try parseThinMach()
    }
    private func cpuName(_ cpu: UInt64) -> String {
        [UInt64(7):"x86",12:"ARM",18:"PowerPC",0x01000007:"x86-64",0x0100000c:"ARM64",0x0200000c:"ARM64_32",0x01000012:"PowerPC64"][cpu] ?? hex(cpu)
    }
    private func parseFat(_ magic: UInt64) throws {
        let fat64 = magic == 0xcafebabf || magic == 0xbfbafeca
        r.little = magic == 0xbebafeca || magic == 0xbfbafeca
        let count = try r.integer(4,4), stride = fat64 ? 32 : 20
        guard count <= 64 else { throw HexaError.message("Universal Mach-O exceeds the 64-slice limit (or is a Java class file sharing CAFEBABE).") }
        nodes.append(try node("Universal header", value: "\(count) architectures", range: r.span(0,8), kind: .header, children: fields(0, [("Magic",0,4),("Architecture count",4,4)])))
        try r.table(8,count:count,stride:stride,minimum:stride)
        let parent = r
        var architectures: [String] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let a = 8+index*stride, cpu = try r.uint(a,4), name = cpuName(cpu)
            architectures.append(name)
            let offset = try r.integer(a+8,fat64 ? 8:4), size = try r.integer(a+(fat64 ? 16:12),fat64 ? 8:4)
            var specs = [("CPU type",0,4),("CPU subtype",4,4),("Slice file offset",8,fat64 ? 8:4),("Slice size",fat64 ? 16:12,fat64 ? 8:4),("Alignment exponent",fat64 ? 24:16,4)]
            if fat64 { specs.append(("Reserved",28,4)) }
            let descriptor = try node("Architecture descriptor", range: r.span(a,stride), kind: .header, children: fields(a,specs))
            var children = [descriptor], range: Range<Int>?
            do {
                range = try r.span(offset,size)
                guard offset >= 8+count*stride else { throw HexaError.message("Slice overlaps the universal header/table.") }
                r = BinaryReader(store: parent.store,bounds: range!)
                let before = nodes; nodes = []
                do { try parseThinMach() }
                catch is CancellationError { nodes = before; r = parent; throw CancellationError() }
                catch { warnings.append("Slice \(index): \(error.localizedDescription)") }
                children += nodes; nodes = before; r = parent
            } catch is CancellationError { throw CancellationError() }
            catch { r = parent; warnings.append("Slice \(index): \(error.localizedDescription)") }
            nodes.append(try node("Slice \(index) · \(name)", value: "\(size.formatted()) bytes", range: range, kind: .segment, children: children))
        }
        architecture = architectures.joined(separator: ", ")
    }
    private func parseThinMach() throws {
        let magic = try r.uint(0,4,littleEndian:false)
        guard [0xfeedface,0xcefaedfe,0xfeedfacf,0xcffaedfe].contains(magic) else { throw HexaError.message("Missing thin Mach-O signature.") }
        r.little = magic == 0xcefaedfe || magic == 0xcffaedfe
        let is64 = magic == 0xfeedfacf || magic == 0xcffaedfe, header = is64 ? 32:28
        _ = try r.span(0,header)
        architecture = cpuName(try r.uint(4,4))
        var specs = [("Magic",0,4),("CPU type",4,4),("CPU subtype",8,4),("File type",12,4),("Load command count",16,4),("Load commands byte size",20,4),("Flags",24,4)]
        if is64 { specs.append(("Reserved",28,4)) }
        nodes.append(try node("Mach-O header", value: "\(architecture) · \(is64 ? 64:32)-bit · \(r.little ? "little":"big") endian", range: r.span(0,header), kind: .header, children: fields(0,specs)))
        let count = try r.integer(16,4), commandsSize = try r.integer(20,4)
        guard count <= 4096 else { throw HexaError.message("Mach-O exceeds the 4,096-command limit.") }
        _ = try r.span(header,commandsSize)
        let end = header+commandsSize
        var cursor = header
        for index in 0..<count {
            guard cursor <= end, end-cursor >= 8 else { throw HexaError.message("Load command count exceeds sizeofcmds.") }
            let command = try r.uint(cursor,4), size = try r.integer(cursor+4,4), baseCommand = command & 0x7fffffff
            guard size >= 8, size <= end-cursor, size.isMultiple(of: is64 ? 8:4) else { throw HexaError.message("Invalid load command size at \(hex(UInt64(cursor))).") }
            var children = try fields(cursor,[("Command",0,4),("Command size",4,4)])
            let names: [UInt64:String] = [1:"LC_SEGMENT",2:"LC_SYMTAB",3:"LC_SYMSEG",4:"LC_THREAD",5:"LC_UNIXTHREAD",11:"LC_DYSYMTAB",12:"LC_LOAD_DYLIB",13:"LC_ID_DYLIB",14:"LC_LOAD_DYLINKER",15:"LC_ID_DYLINKER",24:"LC_LOAD_WEAK_DYLIB",25:"LC_SEGMENT_64",27:"LC_UUID",28:"LC_RPATH",29:"LC_CODE_SIGNATURE",30:"LC_SEGMENT_SPLIT_INFO",31:"LC_REEXPORT_DYLIB",32:"LC_LAZY_LOAD_DYLIB",33:"LC_ENCRYPTION_INFO",34:"LC_DYLD_INFO",35:"LC_LOAD_UPWARD_DYLIB",36:"LC_VERSION_MIN_MACOSX",37:"LC_VERSION_MIN_IPHONEOS",38:"LC_FUNCTION_STARTS",40:"LC_MAIN",41:"LC_DATA_IN_CODE",42:"LC_SOURCE_VERSION",43:"LC_DYLIB_CODE_SIGN_DRS",44:"LC_ENCRYPTION_INFO_64",46:"LC_LINKER_OPTIMIZATION_HINT",49:"LC_NOTE",50:"LC_BUILD_VERSION",51:"LC_DYLD_EXPORTS_TRIE",52:"LC_DYLD_CHAINED_FIXUPS"]
            let name = names[baseCommand] ?? "Load command \(hex(command))"
            var value = "\(size) bytes"
            func require(_ minimum: Int) throws { if size < minimum { throw HexaError.message("\(name) is smaller than its required fields.") } }
            if baseCommand == 1 || baseCommand == 25 {
                let wide = baseCommand == 25, width = wide ? 8:4, fixed = wide ? 72:56, sectionSize = wide ? 80:68
                try require(fixed)
                let segment = try r.string(cursor+8,16), offset = try r.integer(cursor+(wide ? 40:32),width), fileSize = try r.integer(cursor+(wide ? 48:36),width)
                let sectionCount = try r.integer(cursor+(wide ? 64:48),4)
                guard sectionCount <= 4096, sectionCount <= (size-fixed)/sectionSize else { throw HexaError.message("Section count extends beyond its segment command.") }
                value = segment
                children += [try textField("Segment name",cursor+8,16)]
                children += try fields(cursor,[("Virtual address",24,width),("Virtual size",24+width,width),("File offset",24+width*2,width),("File size",24+width*3,width),("Maximum protection",24+width*4,4),("Initial protection",28+width*4,4),("Section count",32+width*4,4),("Flags",36+width*4,4)])
                if fileSize > 0 { children.append(try region("\(segment) segment bytes",offset:offset,size:fileSize,kind:.segment)) }
                for section in 0..<sectionCount {
                    let s = cursor+fixed+section*sectionSize, sectionName = try r.string(s,16)
                    let sectionOffset = try r.integer(s+(wide ? 48:40),4), sectionBytes = try r.integer(s+(wide ? 40:36),width), flags = try r.uint(s+(wide ? 64:56),4)
                    let memoryOnly = [UInt64(1),12,18].contains(flags & 0xff)
                    var sectionFields = [try textField("Section name",s,16), try textField("Segment name",s+16,16)]
                    sectionFields += try fields(s,[("Virtual address",32,width),("Size",32+width,width),("File offset",32+2*width,4),("Alignment exponent",36+2*width,4),("Relocation file offset",40+2*width,4),("Relocation count",44+2*width,4),("Flags",48+2*width,4),("Reserved 1",52+2*width,4),("Reserved 2",56+2*width,4)])
                    if wide { sectionFields.append(try field("Reserved 3",s+76,4)) }
                    if !memoryOnly, sectionBytes > 0 { sectionFields.append(try region("\(sectionName) bytes",offset:sectionOffset,size:sectionBytes,kind:.payload)) }
                    children.append(try node(sectionName, value: "\(sectionBytes.formatted()) \(memoryOnly ? "memory bytes · zero fill":"file bytes")",range:r.span(s,sectionSize),kind:.section,children:sectionFields))
                }
            } else if [12,13,24,31,32,35].contains(baseCommand) {
                try require(24)
                children += try fields(cursor,[("Name command offset",8,4),("Timestamp",12,4),("Current version",16,4),("Compatibility version",20,4)])
                let offset = try r.integer(cursor+8,4)
                guard offset >= 24, offset < size else { throw HexaError.message("Invalid dylib name offset.") }
                value = try r.cstring(cursor+offset,end:cursor+size)
                children.append(try node("Library path",value:value,range:r.span(cursor+offset,min(value.utf8.count+1,size-offset)),kind:.field))
            } else if [14,15,28].contains(baseCommand) {
                try require(12); let offset = try r.integer(cursor+8,4)
                guard offset >= 12, offset < size else { throw HexaError.message("Invalid load-command string offset.") }
                value = try r.cstring(cursor+offset,end:cursor+size)
                children.append(try node("Path",value:value,range:r.span(cursor+offset,min(value.utf8.count+1,size-offset)),kind:.field))
            } else if baseCommand == 27 {
                try require(24); value = ByteFormatting.hex(try r.bytes(cursor+8,16),separator:"")
                children.append(try node("UUID",value:value,range:r.span(cursor+8,16),kind:.field))
            } else if baseCommand == 2 {
                try require(24); children += try fields(cursor,[("Symbol file offset",8,4),("Symbol count",12,4),("String table file offset",16,4),("String table size",20,4)])
                let symbols = try r.integer(cursor+12,4)
                children.append(try region("Symbol table data",offset:r.integer(cursor+8,4),size:symbols*(is64 ? 16:12),kind:.directory))
                children.append(try region("String table data",offset:r.integer(cursor+16,4),size:r.integer(cursor+20,4),kind:.directory))
            } else if [29,30,38,41,43,46,51,52].contains(baseCommand) {
                try require(16); children += try fields(cursor,[("Data file offset",8,4),("Data size",12,4)])
                children.append(try region("\(name) data",offset:r.integer(cursor+8,4),size:r.integer(cursor+12,4),kind:.directory))
            } else if baseCommand == 33 || baseCommand == 44 {
                try require(baseCommand == 44 ? 24:20)
                let cryptID = try r.uint(cursor+16,4); encrypted = encrypted || cryptID != 0
                children += try fields(cursor,[("Encrypted file offset",8,4),("Encrypted size",12,4),("Encryption ID",16,4)])
                value = cryptID == 0 ? "Encryption disabled" : "Declared encrypted · ID \(cryptID)"
                children.append(try region("Encryption region",offset:r.integer(cursor+8,4),size:r.integer(cursor+12,4),kind:.payload,detail:value))
            } else if baseCommand == 34 {
                try require(48)
                for (i,label) in ["Rebase","Bind","Weak bind","Lazy bind","Export"].enumerated() {
                    let field = cursor+8+i*8
                    children += try fields(field,[("\(label) file offset",0,4),("\(label) size",4,4)])
                    let n = try r.integer(field+4,4)
                    if n > 0 { children.append(try region("\(label) data",offset:r.integer(field,4),size:n,kind:.directory)) }
                }
            } else if baseCommand == 40 {
                try require(24); children += try fields(cursor,[("Entry file offset",8,8),("Stack size",16,8)])
                children.append(try region("Entry point",offset:r.integer(cursor+8,8),size:1))
            } else if baseCommand == 50 {
                try require(24); children += try fields(cursor,[("Platform",8,4),("Minimum OS packed version",12,4),("SDK packed version",16,4),("Build tool count",20,4)])
                let toolCount = try r.integer(cursor+20,4)
                guard toolCount <= (size-24)/8 else { throw HexaError.message("Build tool table exceeds LC_BUILD_VERSION.") }
                for i in 0..<toolCount { children.append(try node("Build tool \(i)",range:r.span(cursor+24+i*8,8),kind:.header,children:fields(cursor+24+i*8,[("Tool",0,4),("Packed version",4,4)]))) }
            } else if size > 8 {
                children.append(try node("Command payload",value:ByteFormatting.hex(try r.bytes(cursor+8,min(size-8,16))),range:r.span(cursor+8,size-8),kind:.payload,detail:"Opaque payload; this command's specialized fields are not decoded."))
            }
            nodes.append(try node("\(index) · \(name)",value:value,range:r.span(cursor,size),kind:baseCommand == 1 || baseCommand == 25 ? .segment:.header,children:children))
            cursor += size
        }
        if cursor != end { warnings.append("Load-command sizes do not consume sizeofcmds exactly.") }
    }
}
