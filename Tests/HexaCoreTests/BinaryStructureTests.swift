import XCTest
@testable import HexaCore

enum ExecutableFixtures {
    static func put(_ data:inout Data,_ offset:Int,_ value:UInt64,_ width:Int,_ little:Bool = true) {
        for i in 0..<width { data[offset+i] = UInt8(truncatingIfNeeded:value >> ((little ? i:width-1-i)*8)) }
    }
    static func text(_ data:inout Data,_ offset:Int,_ text:String) { data.replaceSubrange(offset..<offset+text.utf8.count,with:Data(text.utf8)) }
    static func pe(wide:Bool = true)->Data {
        var d = Data(repeating:0,count:1024); text(&d,0,"MZ"); put(&d,60,128,4); text(&d,128,"PE\0\0")
        put(&d,132,wide ? 0x8664:0x14c,2);put(&d,134,2,2);put(&d,148,wide ? 240:224,2);put(&d,150,0x22,2)
        let o = 152;put(&d,o,wide ? 0x20b:0x10b,2);put(&d,o+16,0x1000,4);put(&d,o+(wide ? 24:28),wide ? 0x140000000:0x400000,wide ? 8:4)
        put(&d,o+32,4096,4);put(&d,o+36,512,4);put(&d,o+56,0x3000,4);put(&d,o+60,512,4);put(&d,o+(wide ? 108:92),16,4)
        let directories = o+(wide ? 112:96);put(&d,directories+8,0x2000,4);put(&d,directories+12,16,4);put(&d,directories+32,768,4);put(&d,directories+36,24,4)
        let s = o+(wide ? 240:224);text(&d,s,".text");put(&d,s+8,128,4);put(&d,s+12,0x1000,4);put(&d,s+16,128,4);put(&d,s+20,512,4);put(&d,s+36,0x60000020,4)
        text(&d,s+40,".data");put(&d,s+48,64,4);put(&d,s+52,0x2000,4);put(&d,s+56,64,4);put(&d,s+60,640,4);put(&d,s+76,0xc0000040,4)
        for i in 512..<640 { d[i] = UInt8(truncatingIfNeeded:i) };text(&d,640,"Example imports");return d
    }
    static func elf(wide:Bool = true,little:Bool = true,extended:Bool = false)->Data {
        var d = Data(repeating:0,count:1024)
        func write(_ o:Int,_ v:UInt64,_ w:Int) { put(&d,o,v,w,little) }
        d.replaceSubrange(0..<4,with:[0x7f,0x45,0x4c,0x46]);d[4] = wide ? 2:1;d[5] = little ? 1:2;d[6] = 1
        let width = wide ? 8:4, h = wide ? 64:52, sizes = wide ? 52:40, p = h, sh = wide ? 256:128, stride = wide ? 64:40
        write(16,2,2);write(18,wide ? 62:40,2);write(20,1,4);write(24,0x400000,width);write(24+width,UInt64(p),width);write(24+width*2,UInt64(sh),width)
        write(sizes,UInt64(h),2);write(sizes+2,wide ? 56:32,2);write(sizes+4,extended ? 0xffff:1,2);write(sizes+6,UInt64(stride),2);write(sizes+8,extended ? 0:4,2);write(sizes+10,extended ? 0xffff:2,2)
        write(p,1,4);write(p+(wide ? 4:24),5,4);write(p+(wide ? 8:4),512,width);write(p+(wide ? 16:8),0x400000,width);write(p+(wide ? 32:16),64,width);write(p+(wide ? 40:20),512,width)
        if extended { write(sh+(wide ? 32:20),4,width);write(sh+(wide ? 40:24),2,4);write(sh+(wide ? 44:28),1,4) }
        for (index,name,type,offset,size) in [(1,1,1,512,64),(2,7,3,640,22),(3,17,8,0xf000,512)] {
            let s = sh+index*stride;write(s,UInt64(name),4);write(s+4,UInt64(type),4);write(s+(wide ? 24:16),UInt64(offset),width);write(s+(wide ? 32:20),UInt64(size),width)
        }
        text(&d,640,"\0.text\0.shstrtab\0.bss\0\0")
        for i in 512..<576 { d[i] = UInt8(truncatingIfNeeded:i*7) };return d
    }
    static func mach(wide:Bool = true,little:Bool = true,encrypted:Bool = false)->Data {
        var d = Data(repeating:0,count:1024)
        func write(_ o:Int,_ v:UInt64,_ w:Int) { put(&d,o,v,w,little) }
        let h = wide ? 32:28, fixed = wide ? 72:56, sectionSize = wide ? 80:68, segmentSize = fixed+sectionSize, cryptoSize = wide ? 24:20, total = segmentSize+24+cryptoSize
        write(0,wide ? 0xfeedfacf:0xfeedface,4);write(4,wide ? 0x100000c:7,4);write(8,0,4);write(12,2,4);write(16,3,4);write(20,UInt64(total),4)
        write(h,wide ? 25:1,4);write(h+4,UInt64(segmentSize),4);text(&d,h+8,"__TEXT")
        let width = wide ? 8:4;write(h+24,0x100000,width);write(h+24+width,4096,width);write(h+24+width*2,0,width);write(h+24+width*3,1024,width);write(h+24+width*4,5,4);write(h+28+width*4,5,4);write(h+32+width*4,1,4)
        let s = h+fixed;text(&d,s,"__text");text(&d,s+16,"__TEXT");write(s+32,0x100200,width);write(s+32+width,256,width);write(s+32+width*2,512,4)
        let uuid = h+segmentSize;write(uuid,27,4);write(uuid+4,24,4);for i in 0..<16 { d[uuid+8+i] = UInt8(i) }
        let crypt = uuid+24;write(crypt,wide ? 44:33,4);write(crypt+4,UInt64(cryptoSize),4);write(crypt+8,512,4);write(crypt+12,256,4);write(crypt+16,encrypted ? 1:0,4)
        for i in 512..<768 { d[i] = UInt8(truncatingIfNeeded:i) };return d
    }
    static func fat(wide:Bool = false,little:Bool = false)->Data {
        var d = Data(repeating:0,count:8192);put(&d,0,wide ? 0xcafebabf:0xcafebabe,4,little);put(&d,4,2,4,little)
        let stride = wide ? 32:20
        for (i,cpu,offset) in [(0,0x100000c,4096),(1,7,6144)] {
            let a = 8+i*stride;put(&d,a,UInt64(cpu),4,little);put(&d,a+8,UInt64(offset),wide ? 8:4,little);put(&d,a+(wide ? 16:12),1024,wide ? 8:4,little);put(&d,a+(wide ? 24:16),10,4,little)
            d.replaceSubrange(offset..<offset+1024,with:mach(wide:i == 0,little:i == 0))
        };return d
    }
}

final class BinaryStructureTests:XCTestCase {
    func testPE32AndPE64AndRVAFileOffsetDistinction() throws {
        for wide in [false,true] {
            let report = try BinaryStructure.parse(ByteStore(ExecutableFixtures.pe(wide:wide)))
            XCTAssertTrue(report.warnings.isEmpty,report.warnings.joined(separator:"\n"))
            XCTAssertEqual(report.architecture,wide ? "x86-64":"x86")
            XCTAssertEqual(report.allNodes.first { $0.name == ".text bytes" }?.range,512..<640)
            XCTAssertEqual(report.allNodes.first { $0.name == "Imports data" }?.range,640..<656)
            XCTAssertEqual(report.allNodes.first { $0.name == "Certificates (file offset) data" }?.range,768..<792)
            XCTAssertEqual(report.allNodes.first { $0.name == "Entry point" }?.range,512..<513)
        }
    }
    func testELFClassesEndiannessAndMemoryOnlySections() throws {
        for wide in [false,true] { for little in [false,true] {
            let report = try BinaryStructure.parse(ByteStore(ExecutableFixtures.elf(wide:wide,little:little)))
            XCTAssertTrue(report.warnings.isEmpty,report.warnings.joined(separator:"\n"))
            XCTAssertNotNil(report.allNodes.first { $0.name == ".text" })
            XCTAssertEqual(report.allNodes.first { $0.name == ".text bytes" }?.range,512..<576)
            XCTAssertNil(report.allNodes.first { $0.name == ".bss bytes" })
            XCTAssertTrue(report.allNodes.first { $0.name == ".bss" }?.value.contains("no bytes") == true)
        } }
    }
    func testELFExtendedNumbering() throws {
        let report = try BinaryStructure.parse(ByteStore(ExecutableFixtures.elf(extended:true)))
        XCTAssertTrue(report.warnings.isEmpty,report.warnings.joined(separator:"\n"))
        XCTAssertEqual(report.nodes.first { $0.name == "Section headers" }?.children?.count,4)
        XCTAssertEqual(report.nodes.first { $0.name == "Program headers / segments" }?.children?.count,1)
    }
    func testMachClassesAndBothByteOrders() throws {
        for wide in [false,true] { for little in [false,true] {
            let report = try BinaryStructure.parse(ByteStore(ExecutableFixtures.mach(wide:wide,little:little,encrypted:true)))
            XCTAssertTrue(report.warnings.isEmpty,report.warnings.joined(separator:"\n"))
            XCTAssertTrue(report.declaredEncrypted)
            XCTAssertEqual(report.allNodes.first { $0.name == "__text bytes" }?.range,512..<768)
            XCTAssertTrue(report.allNodes.contains { $0.name == "UUID" })
        } }
    }
    func testUniversalArchitecturesKeepSliceRelativeOffsets() throws {
        for wide in [false,true] { for little in [false,true] {
            let report = try BinaryStructure.parse(ByteStore(ExecutableFixtures.fat(wide:wide,little:little)))
            XCTAssertTrue(report.warnings.isEmpty,report.warnings.joined(separator:"\n"))
            XCTAssertEqual(report.architecture,"ARM64, x86")
            XCTAssertEqual(report.allNodes.filter { $0.name == "__text bytes" }.compactMap(\.range),[4608..<4864,6656..<6912])
        } }
    }
    func testEmbeddedSelectionOffsets() throws {
        let image = ExecutableFixtures.pe(), prefix = Data(repeating:0xcc,count:37)
        let report = try BinaryStructure.parse(ByteStore(prefix+image+prefix),range:37..<1061)
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertEqual(report.allNodes.first { $0.name == ".text bytes" }?.range,549..<677)
        XCTAssertTrue(report.regions.allSatisfy { $0.range.lowerBound >= 37 && $0.range.upperBound <= 1061 })
    }
    func testMalformedTruncatedAndHostileInputsNeverExposeInvalidRanges() throws {
        var random = Generator()
        for fixture in [ExecutableFixtures.pe(),ExecutableFixtures.elf(),ExecutableFixtures.mach(),ExecutableFixtures.fat()] {
            for _ in 0..<100 {
                var data = fixture
                let length = Int.random(in:0...data.count,using:&random);data = data.prefix(length)
                if data.count > 8 { for _ in 0..<8 { data[Int.random(in:4..<data.count,using:&random)] = UInt8.random(in:0...255,using:&random) } }
                let report = try BinaryStructure.parse(ByteStore(data))
                XCTAssertTrue(report.regions.allSatisfy { $0.range.lowerBound >= 0 && $0.range.upperBound <= data.count })
                XCTAssertLessThanOrEqual(report.allNodes.count,30_000)
            }
        }
        var bad = ExecutableFixtures.elf();ExecutableFixtures.put(&bad,32,UInt64.max,8)
        XCTAssertFalse(try BinaryStructure.parse(ByteStore(bad)).warnings.isEmpty)
        var invalidCommand = ExecutableFixtures.mach();ExecutableFixtures.put(&invalidCommand,36,0,4)
        XCTAssertFalse(try BinaryStructure.parse(ByteStore(invalidCommand)).warnings.isEmpty)
    }
    func testRawTreeAndForcedParser() throws {
        let data = Data([1,2,3,4,5,6,7,8])
        let raw = try BinaryStructure.parse(ByteStore(data),format:.raw)
        XCTAssertTrue(raw.warnings.isEmpty);XCTAssertTrue(raw.allNodes.contains { $0.name == "UInt64" })
        XCTAssertFalse(try BinaryStructure.parse(ByteStore(data),format:.pe).warnings.isEmpty)
        XCTAssertTrue(try BinaryStructure.parse(ByteStore()).regions.isEmpty)
    }
    func testRealSystemMachO() throws {
        let report = try BinaryStructure.parse(ByteStore.open(URL(fileURLWithPath:"/bin/ls")))
        XCTAssertEqual(report.identity.format,.machO)
        XCTAssertTrue(report.warnings.isEmpty,report.warnings.joined(separator:"\n"))
        XCTAssertTrue(report.allNodes.contains { $0.name == "__TEXT" || $0.name == "__text" })
    }
}
