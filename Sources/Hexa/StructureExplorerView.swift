import SwiftUI
import AppKit
import HexaCore

enum StructurePalette {
    static let colors: [Color] = [.blue,.teal,.purple,.orange,.pink,.indigo,.green,.cyan]
    static func color(_ index: Int) -> Color { colors[index % colors.count] }
    static func nsColor(_ index: Int) -> NSColor { [.systemBlue,.systemTeal,.systemPurple,.systemOrange,.systemPink,.systemIndigo,.systemGreen,.systemCyan][index % 8] }
}

struct StructureExplorerView: View {
    @ObservedObject var model: EditorModel
    @State private var containerID: UUID?
    @State private var filter = ""
    private var allNodes: [BinaryNode] { model.structure?.allNodes ?? [] }
    private var container: BinaryNode? { allNodes.first { $0.id == containerID } ?? model.structure?.nodes.first }
    private var rows: [BinaryNode] {
        if !filter.isEmpty { return allNodes.filter { $0.name.localizedCaseInsensitiveContains(filter) || $0.value.localizedCaseInsensitiveContains(filter) } }
        guard let container else { return [] }; return container.children ?? [container]
    }
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"list.bullet.indent").font(.system(size:25,weight:.light)).foregroundStyle(.blue)
                VStack(alignment:.leading,spacing:4) {
                    Text("File structure").font(.system(size:20,weight:.semibold))
                    Text(model.structure.map { "\($0.identity.name) · \($0.architecture)" } ?? "Decode headers, segments, sections, and fields.").font(.system(size:11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Color fields",isOn:$model.showStructureColors).toggleStyle(.switch).controlSize(.small)
                Picker("Parser",selection:$model.parserFormat) { ForEach(BinaryFormat.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.frame(width:145)
                Button("Decode Selection") { model.parseStructure(selectionOnly:true) }.disabled(model.selection.isEmpty || model.isBusy)
                Button("Decode File") { model.parseStructure() }.disabled(model.isBusy)
            }.padding(20)
            if let report = model.structure {
                StructureMap(report:report) { id in
                    if let node = allNodes.first(where: { $0.id == id }) { containerID = node.id; model.selectStructureNode(node) }
                }.frame(height:65).padding(.horizontal,20).padding(.bottom,16)
                if !report.warnings.isEmpty {
                    DisclosureGroup {
                        VStack(alignment:.leading,spacing:6) { ForEach(Array(report.warnings.enumerated()),id:\.offset) { _,text in Text(text).frame(maxWidth:.infinity,alignment:.leading) } }.font(.system(size:11)).foregroundStyle(.secondary).padding(.vertical,8)
                    } label: { Label("\(report.warnings.count) parsing notices · decoded fields remain available",systemImage:"exclamationmark.triangle").font(.system(size:11)).foregroundStyle(.orange) }.padding(.horizontal,20).padding(.bottom,12)
                }
                Divider()
                HSplitView {
                    List(selection:Binding<UUID?>(get:{ containerID ?? report.nodes.first?.id },set:{ id in
                        containerID = id; filter = ""
                        if let node = allNodes.first(where:{ $0.id == id }) { model.selectStructureNode(node) }
                    })) {
                        OutlineGroup(report.nodes,children:\.children) { node in
                            HStack(spacing:7) {
                                RoundedRectangle(cornerRadius:2).fill(StructurePalette.color(node.colorIndex)).frame(width:7,height:12)
                                Text(node.name).font(.system(size:11)).lineLimit(1).help(node.name)
                            }.tag(node.id).padding(.vertical,3)
                        }
                    }.listStyle(.sidebar).frame(minWidth:220,idealWidth:285,maxWidth:400)
                    VStack(alignment:.leading,spacing:0) {
                        HStack {
                            VStack(alignment:.leading,spacing:4) { Text(container?.name ?? "Fields").font(.system(size:15,weight:.semibold)); Text("Click a field to select its bytes. Offsets are absolute file positions.").font(.system(size:10)).foregroundStyle(.secondary) }
                            Spacer()
                            TextField("Filter all fields",text:$filter).textFieldStyle(.roundedBorder).frame(width:185)
                        }.padding(16)
                        Table(rows,selection:Binding<UUID?>(get:{model.selectedStructureNode?.id},set:{ id in if let node = allNodes.first(where:{$0.id == id}) { model.selectStructureNode(node) } })) {
                            TableColumn("Field") { node in HStack(spacing:7) { Circle().fill(StructurePalette.color(node.colorIndex)).frame(width:6,height:6); Text(node.name).font(.system(size:11,weight:.medium)) } }.width(min:150,ideal:210)
                            TableColumn("Value") { node in Text(node.value).font(.system(size:11,design:.monospaced)).lineLimit(2).help(node.value) }.width(min:160,ideal:330)
                            TableColumn("Offset") { node in Text(node.range.map { "0x"+String($0.lowerBound,radix:16).uppercased() } ?? "—").font(.system(size:10,design:.monospaced)) }.width(105)
                            TableColumn("Bytes") { node in Text(node.range.map { $0.count.formatted() } ?? "—").font(.system(size:10,design:.monospaced)) }.width(80)
                        }.alternatingRowBackgrounds(.enabled)
                        if let selected = model.selectedStructureNode ?? container {
                            Divider()
                            VStack(alignment:.leading,spacing:10) {
                                HStack { Label(selected.name,systemImage:"scope").font(.system(size:12,weight:.semibold)).foregroundStyle(StructurePalette.color(selected.colorIndex)); Spacer(); if let range = selected.range { Button("Show in Bytes") { model.showBytes(range) }.controlSize(.small) } }
                                Text(selected.value).font(.system(size:11,design:.monospaced)).textSelection(.enabled)
                                if !selected.detail.isEmpty { Text(selected.detail).font(.system(size:11)).foregroundStyle(.secondary).textSelection(.enabled) }
                                if let range = selected.range, !range.isEmpty { Text(ByteFormatting.hex(model.store.data(in:range.lowerBound..<(range.lowerBound+min(32,range.count))))).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
                            }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(.bar)
                        }
                    }.frame(minWidth:650,maxWidth:.infinity,maxHeight:.infinity)
                }
            } else {
                VStack(spacing:16) {
                    Image(systemName:"square.stack.3d.up").font(.system(size:48,weight:.ultraLight)).foregroundStyle(.tertiary)
                    Text(model.isBusy ? "Decoding…":"Ready to decode").font(.title3)
                    Text("Choose automatic detection or a parser. Unknown bytes receive a raw interpretation tree.").foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }.background(Color(nsColor:.controlBackgroundColor))
    }
}

struct StructureMap: View {
    let report: StructureReport
    let select: (UUID)->Void
    @State private var hovered: BinaryRegion?
    private var regions: [BinaryRegion] { report.regions.filter { $0.kind != .field && $0.kind != .group }.sorted { $0.range.count > $1.range.count } }
    private func lane(_ region: BinaryRegion) -> Int { region.kind == .header ? 0 : region.kind == .section || region.kind == .segment ? 1:2 }
    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            GeometryReader { geo in
                Canvas { context,size in
                    for row in 0..<3 { context.fill(Path(roundedRect:CGRect(x:0,y:CGFloat(row)*13,width:size.width,height:10),cornerRadius:3),with:.color(.primary.opacity(0.035))) }
                    guard !report.range.isEmpty else { return }
                    for region in regions {
                        let x = Double(region.range.lowerBound-report.range.lowerBound)/Double(report.range.count)*size.width
                        let width = max(1,Double(region.range.count)/Double(report.range.count)*size.width)
                        context.fill(Path(roundedRect:CGRect(x:x,y:CGFloat(lane(region))*13,width:width,height:10),cornerRadius:2),with:.color(StructurePalette.color(region.colorIndex).opacity(0.75)))
                    }
                }
                .onContinuousHover { phase in
                    if case .active(let point) = phase { hovered = hit(point,width:geo.size.width) } else { hovered = nil }
                }
                .onTapGesture { point in if let region = hit(point,width:geo.size.width) { select(region.id) } }
            }.frame(height:38)
            HStack {
                Text(hovered.map { "\($0.name) · 0x\(String($0.range.lowerBound,radix:16).uppercased()) · \($0.range.count.formatted()) bytes" } ?? "File map · headers / segments & sections / payloads").lineLimit(1)
                Spacer(); Text("\(report.range.count.formatted()) bytes")
            }.font(.system(size:10)).foregroundStyle(.secondary)
        }.accessibilityLabel("File region map. Regions can also be selected in the structure tree.")
    }
    private func hit(_ point: CGPoint,width: Double) -> BinaryRegion? {
        guard width > 0, !report.range.isEmpty else { return nil }
        let offset = report.range.lowerBound + min(report.range.count-1,max(0,Int(point.x/width*Double(report.range.count))))
        return regions.reversed().first { lane($0) == Int(point.y/13) && $0.range.contains(offset) }
    }
}
