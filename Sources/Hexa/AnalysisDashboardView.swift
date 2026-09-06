import SwiftUI
import Charts
import AppKit
import HexaCore

enum AnalysisColors {
    static let types: [Color] = [.gray,.cyan,.green,.orange,.purple,.pink]
    static func offset(_ value: Int) -> String { "0x"+String(value,radix:16).uppercased() }
}

struct AnalysisDashboardView: View {
    @ObservedObject var model: EditorModel
    @State private var showDatabase = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                HStack(spacing:13) {
                    Image(systemName:"chart.xyaxis.line").font(.system(size:27,weight:.light)).foregroundStyle(.blue)
                    VStack(alignment:.leading,spacing:4) { Text("Byte analysis").font(.system(size:24,weight:.semibold)); Text("Patterns, structure, and signals in your data.").font(.system(size:12)).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Signature Database") { showDatabase = true }
                    Button("Analyze Selection") { model.analyze(selectionOnly:true) }.disabled(model.selection.isEmpty || model.isBusy)
                    Button("Analyze File") { model.analyze() }.buttonStyle(.borderedProminent).disabled(model.isBusy)
                }
                if let report = model.analysis, let range = model.analysisRange {
                    dashboard(report,range:range)
                } else {
                    VStack(spacing:18) {
                        Image(systemName:"waveform.path").font(.system(size:58,weight:.ultraLight)).foregroundStyle(.blue.opacity(0.55))
                        Text(model.isBusy ? "Measuring the bytes…":"A new perspective on your file").font(.system(size:20,weight:.medium))
                        Text("Explore entropy, byte types, adjacent-byte pairs, distributions, and cryptographic constants.").foregroundStyle(.secondary)
                        if model.isBusy { ProgressView().controlSize(.small) }
                    }.frame(maxWidth:.infinity).padding(.vertical,120)
                }
            }.padding(24)
        }.background(Color(nsColor:.windowBackgroundColor))
        .sheet(isPresented:$showDatabase) { MagicDatabaseView() }
    }
    @ViewBuilder private func dashboard(_ report: AnalysisReport, range: Range<Int>) -> some View {
        let signals = report.signals
        HStack(alignment:.top,spacing:20) {
            VStack(alignment:.leading,spacing:9) {
                Text(signals.identity.category.rawValue.uppercased()).font(.system(size:9,weight:.semibold)).tracking(1).foregroundStyle(.blue)
                Text(signals.identity.name).font(.system(size:18,weight:.semibold))
                Text(signals.identity.mime).font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                Text(signals.identity.evidence).font(.system(size:10)).foregroundStyle(.tertiary)
            }.frame(maxWidth:.infinity,alignment:.leading)
            Divider()
            VStack(alignment:.leading,spacing:9) {
                Label(signals.assessment.title,systemImage:"sparkle.magnifyingglass").font(.system(size:14,weight:.medium)).foregroundStyle(.teal)
                Text(signals.assessment.detail).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Text(signals.assessment.evidence).font(.system(size:10,design:.monospaced)).foregroundStyle(.tertiary)
                if model.structure?.declaredEncrypted == true { Label("Mach-O declares an encrypted region",systemImage:"lock").font(.system(size:11)).foregroundStyle(.orange) }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }.padding(20).background(cardBackground,in:RoundedRectangle(cornerRadius:12))
        HStack(spacing:14) {
            metric("AVERAGE ENTROPY",String(format:"%.4f",signals.averageEntropy),"weighted windows · bits/byte",.blue)
            metric("HIGHEST ENTROPY",String(format:"%.4f",signals.highestEntropy),"maximum window · bits/byte",.purple)
            metric("GLOBAL ENTROPY",String(format:"%.4f",report.entropy),"whole analyzed range · bits/byte",.teal)
            metric("ANALYZED BYTES",report.count.formatted(),"from \(AnalysisColors.offset(range.lowerBound))",.orange)
        }
        LazyVGrid(columns:[GridItem(.flexible(minimum:350),spacing:18),GridItem(.flexible(minimum:350),spacing:18)],alignment:.leading,spacing:18) {
            AnalysisCard(title:"Entropy graph",subtitle:"\(signals.windowSize.formatted())-byte windows · click a window to inspect",icon:"waveform.path",color:.blue) {
                EntropyGraph(windows:signals.windows,range:range) { model.showBytes($0) }.frame(height:220)
            }
            AnalysisCard(title:"Byte types over the file",subtitle:"Exact composition in each entropy window",icon:"chart.bar.xaxis",color:.purple) {
                ByteTypeGraph(windows:signals.windows,range:range) { model.showBytes($0) }.frame(height:190)
                typeLegend(signals.byteTypes,total:report.count)
            }
            AnalysisCard(title:"Digram distribution",subtitle:"Previous byte → next byte · brightness is log frequency",icon:"square.grid.3x3.fill",color:.cyan) {
                DistributionHeatmap(report:report,range:range,layered:false) { first,second in model.findDigram(first,second) }.frame(height:267)
            }
            AnalysisCard(title:"Layered byte distribution",subtitle:"File position → byte value · exact counts in up to 256 bins",icon:"square.3.layers.3d",color:.pink) {
                DistributionHeatmap(report:report,range:range,layered:true) { column,_ in
                    let start = range.lowerBound+column*signals.layerSize
                    model.showBytes(start..<(start+min(signals.layerSize,range.upperBound-start)))
                }.frame(height:267)
            }
            AnalysisCard(title:"Byte value frequency",subtitle:"All 256 byte values, colored by byte type",icon:"chart.bar.fill",color:.green) {
                Chart(0..<256,id:\.self) { byte in
                    BarMark(x:.value("Byte",byte),y:.value("Count",report.histogram[byte])).foregroundStyle(AnalysisColors.types[ByteClass.classify(UInt8(byte))])
                }.chartLegend(.hidden).chartXAxis { AxisMarks(values:[0,64,128,192,255]) { value in AxisValueLabel { if let i = value.as(Int.self) { Text(String(format:"%02X",i)) } } } }.frame(height:190)
                typeLegend(signals.byteTypes,total:report.count)
            }
            AnalysisCard(title:"Cryptographic constants",subtitle:"Exact byte signatures · \(CryptographicConstants.signatures.count) table / byte-order variants",icon:"number.square",color:.orange) {
                if signals.cryptoMatches.isEmpty {
                    VStack(spacing:12) { Image(systemName:"checkmark.seal").font(.system(size:28,weight:.light)).foregroundStyle(.tertiary); Text("No known constants found").font(.system(size:13,weight:.medium)); Text("Algorithms can compute constants at runtime or store them in other forms. An empty result does not rule out cryptography.").font(.system(size:11)).foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth:.infinity).frame(height:206)
                } else {
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:1) {
                            ForEach(signals.cryptoMatches) { match in
                                Button { model.showBytes(match.range) } label: {
                                    HStack {
                                        VStack(alignment:.leading,spacing:4) { Text(match.name).font(.system(size:11,weight:.medium)); Text(match.encoding).font(.system(size:9)).foregroundStyle(.secondary) }
                                        Spacer(); Text(AnalysisColors.offset(match.range.lowerBound)).font(.system(size:10,design:.monospaced)).foregroundStyle(.orange)
                                    }.padding(.vertical,9).padding(.horizontal,5).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }.frame(height:206)
                }
                Text("\(signals.cryptoMatches.count.formatted())\(signals.cryptoTruncated ? "+":"") matches. A constant is a clue, not proof that an algorithm is used or that the file is encrypted.").font(.system(size:10)).foregroundStyle(.secondary)
            }
        }
        DisclosureGroup {
            VStack(alignment:.leading,spacing:13) {
                checksum("SHA-256",report.sha256); checksum("SHA-512",report.sha512); checksum("MD5",report.md5); checksum("CRC-32 / ISO-HDLC",report.crc32)
            }.padding(.top,15)
        } label: { Label("Checksums & fingerprints",systemImage:"number").font(.system(size:13,weight:.medium)) }.padding(18).background(cardBackground,in:RoundedRectangle(cornerRadius:12))
        Text("Graphs cover \(AnalysisColors.offset(range.lowerBound))–\(AnalysisColors.offset(range.upperBound)) (end exclusive). Adjacent pairs stay inside this range. Graphs and detections are invalidated by edits.").font(.system(size:10)).foregroundStyle(.tertiary)
    }
    private var cardBackground: Color { Color.primary.opacity(0.035) }
    private func metric(_ title: String,_ value: String,_ subtitle: String,_ color: Color) -> some View {
        VStack(alignment:.leading,spacing:10) {
            Text(title).font(.system(size:9,weight:.semibold)).tracking(0.8).foregroundStyle(.secondary)
            Text(value).font(.system(size:28,weight:.light,design:.rounded)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            Text(subtitle).font(.system(size:10)).foregroundStyle(.tertiary)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(18).background(cardBackground,in:RoundedRectangle(cornerRadius:10))
    }
    private func typeLegend(_ counts:[Int],total:Int) -> some View {
        LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible()),GridItem(.flexible())],alignment:.leading,spacing:6) {
            ForEach(ByteClass.allCases) { type in
                HStack(spacing:4) { Circle().fill(AnalysisColors.types[type.index]).frame(width:5,height:5); Text(type.rawValue); Text(String(format:"%.1f%%",total == 0 ? 0:Double(counts[type.index])/Double(total)*100)).foregroundStyle(.secondary) }.font(.system(size:9)).help(type.definition)
            }
        }.padding(.top,6)
    }
    private func checksum(_ name:String,_ value:String) -> some View {
        HStack(alignment:.top) { Text(name).font(.system(size:10,weight:.semibold)).frame(width:130,alignment:.leading); Text(value).font(.system(size:11,design:.monospaced)).textSelection(.enabled); Spacer(); Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value,forType:.string) } label: { Image(systemName:"doc.on.doc") }.buttonStyle(.plain).help("Copy \(name)") }
    }
}

struct AnalysisCard<Content:View>: View {
    let title:String; let subtitle:String; let icon:String; let color:Color
    @ViewBuilder let content:()->Content
    var body:some View {
        VStack(alignment:.leading,spacing:13) {
            Label(title,systemImage:icon).font(.system(size:13,weight:.semibold)).foregroundStyle(color)
            Text(subtitle).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(2)
            content()
        }.padding(18).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(Color.primary.opacity(0.05),lineWidth:1))
    }
}

struct EntropyGraph: View {
    let windows:[EntropyWindow]; let range:Range<Int>; let select:(Range<Int>)->Void
    @State private var hovered:Int?
    private var points:[(Double,Double)] { windows.flatMap { [(Double($0.range.lowerBound),$0.entropy),(Double($0.range.upperBound),$0.entropy)] } }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Chart {
                ForEach(Array(points.enumerated()),id:\.offset) { _,point in
                    AreaMark(x:.value("Offset",point.0),y:.value("Entropy",point.1),stacking:.unstacked).foregroundStyle(LinearGradient(colors:[.blue.opacity(0.3),.blue.opacity(0.03)],startPoint:.top,endPoint:.bottom))
                    LineMark(x:.value("Offset",point.0),y:.value("Entropy",point.1)).foregroundStyle(.blue).lineStyle(StrokeStyle(lineWidth:1.7))
                }
                RuleMark(y:.value("High entropy",7.5)).foregroundStyle(.orange.opacity(0.55)).lineStyle(StrokeStyle(lineWidth:1,dash:[3,3]))
                if let hovered, windows.indices.contains(hovered) { RuleMark(x:.value("Hovered offset",Double(windows[hovered].range.lowerBound))).foregroundStyle(.secondary.opacity(0.5)) }
            }.chartYScale(domain:0...8).chartXScale(domain:Double(range.lowerBound)...max(Double(range.lowerBound)+1,Double(range.upperBound)))
                .chartXAxis { offsetAxis() }.chartYAxis { AxisMarks(values:[0,2,4,6,8]) }.chartPlotStyle { $0.clipped() }
                .chartOverlay { proxy in ChartHitLayer(proxy:proxy,windows:windows,hovered:$hovered,select:select) }
            Text(hovered.flatMap { windows.indices.contains($0) ? windows[$0]:nil }.map { "\(AnalysisColors.offset($0.range.lowerBound)) · \($0.range.count.formatted()) bytes · \(String(format:"%.4f",$0.entropy)) bits/byte" } ?? "Hover for values · orange guide: 7.5 bits/byte").font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct ByteTypeGraph: View {
    let windows:[EntropyWindow]; let range:Range<Int>; let select:(Range<Int>)->Void
    @State private var hovered:Int?
    var body:some View {
        Chart {
            ForEach(ByteClass.allCases) { type in
                ForEach(windows) { window in
                    let lower = Double(window.byteTypes.prefix(type.index).reduce(0,+))/Double(max(1,window.range.count))*100
                    let upper = lower+Double(window.byteTypes[type.index])/Double(max(1,window.range.count))*100
                    RectangleMark(xStart:.value("Start",Double(window.range.lowerBound)),xEnd:.value("End",Double(window.range.upperBound)),yStart:.value("From",lower),yEnd:.value("To",upper)).foregroundStyle(AnalysisColors.types[type.index])
                }
            }
        }.chartLegend(.hidden).chartYScale(domain:0...100).chartXScale(domain:Double(range.lowerBound)...max(Double(range.lowerBound)+1,Double(range.upperBound)))
            .chartXAxis { offsetAxis() }.chartYAxis { AxisMarks(values:[0,50,100]) { value in AxisGridLine(); AxisValueLabel { if let n = value.as(Int.self) { Text("\(n)%") } } } }
            .chartOverlay { proxy in ChartHitLayer(proxy:proxy,windows:windows,hovered:$hovered,select:select) }
    }
}

private func offsetAxis() -> some AxisContent {
        AxisMarks(values:.automatic(desiredCount:4)) { value in
            AxisGridLine().foregroundStyle(.gray.opacity(0.12))
            AxisValueLabel { if let offset = value.as(Double.self), offset >= 0 { Text("0x"+String(UInt64(offset),radix:16).uppercased()).font(.system(size:8,design:.monospaced)) } }
        }
}

struct ChartHitLayer:View {
    let proxy:ChartProxy; let windows:[EntropyWindow]; @Binding var hovered:Int?; let select:(Range<Int>)->Void
    var body:some View {
        GeometryReader { geometry in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in if case .active(let point) = phase { hovered = index(point,geometry) } else { hovered = nil } }
                .onTapGesture { point in if let i = index(point,geometry) { select(windows[i].range) } }
        }
    }
    private func index(_ point:CGPoint,_ geometry:GeometryProxy)->Int? {
        guard let anchor = proxy.plotFrame else { return nil }
        let rect = geometry[anchor]
        guard rect.contains(point), let value = proxy.value(atX:point.x-rect.minX,as:Double.self) else { return nil }
        return windows.firstIndex { value >= Double($0.range.lowerBound) && value < Double($0.range.upperBound) }
    }
}

struct DistributionHeatmap:View {
    let report:AnalysisReport; let range:Range<Int>; let layered:Bool; let select:(Int,Int)->Void
    @State private var bitmap:CGImage?
    @State private var hover:(Int,Int)?
    private var width:Int { layered ? report.signals.layerCount:256 }
    private func count(_ x:Int,_ y:Int)->Int { layered ? report.signals.layers[y*width+x]:report.signals.digrams[x*256+y] }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:6) {
                VStack { Text("FF"); Spacer(); Text("00") }.font(.system(size:8,design:.monospaced)).foregroundStyle(.tertiary)
                GeometryReader { geometry in
                    Group {
                        if let bitmap { Image(decorative:bitmap,scale:1).resizable().interpolation(.none) }
                        else { Color.black.opacity(0.85) }
                    }.clipShape(RoundedRectangle(cornerRadius:5)).contentShape(Rectangle())
                        .onContinuousHover { phase in if case .active(let p) = phase { hover = cell(p,geometry.size) } else { hover = nil } }
                        .onTapGesture { p in let (x,y) = cell(p,geometry.size); if layered || count(x,y)>0 { select(x,y) } }
                }
            }
            HStack { Text(layered ? AnalysisColors.offset(range.lowerBound):"00"); Spacer(); Text(layered ? AnalysisColors.offset(range.upperBound):"FF") }.font(.system(size:8,design:.monospaced)).foregroundStyle(.tertiary)
            HStack(spacing:7) { Text("Low"); LinearGradient(colors:[Color(red:0.04,green:0.07,blue:0.12),.blue,.cyan,.yellow],startPoint:.leading,endPoint:.trailing).frame(width:90,height:5).clipShape(Capsule()); Text("High"); Spacer(); Text(layered ? "Click to inspect a position bin":"Click to find the first pair") }.font(.system(size:9)).foregroundStyle(.secondary)
            Text(hover.map { x,y in layered ? "\(AnalysisColors.offset(range.lowerBound+x*report.signals.layerSize)) · byte \(String(format:"%02X",y)) · \(count(x,y).formatted()) occurrences" : "\(String(format:"%02X → %02X",x,y)) · \(count(x,y).formatted()) pairs" } ?? (layered ? "X: file position  ·  Y: byte value":"X: preceding byte  ·  Y: following byte")).font(.system(size:9,design:.monospaced)).foregroundStyle(.secondary).lineLimit(1)
        }.task(id:report.id) { bitmap = raster() }
        .accessibilityLabel(layered ? "Layered distribution heatmap; byte value by file position":"Digram heatmap; previous byte by next byte")
    }
    private func cell(_ point:CGPoint,_ size:CGSize)->(Int,Int) { (max(0,min(width-1,Int(point.x/max(1,size.width)*Double(width)))),255-max(0,min(255,Int(point.y/max(1,size.height)*256)))) }
    private func raster()->CGImage? {
        let values = layered ? report.signals.layers:report.signals.digrams, maximum = max(1,values.max() ?? 1)
        var pixels = [UInt8](repeating:0,count:width*256*4)
        let colors:[(Double,Double,Double)] = [(0.04,0.07,0.12),(0.14,0.28,0.75),(0.1,0.8,0.88),(1,0.88,0.3)]
        for row in 0..<256 { for x in 0..<width {
            let level = log1p(Double(count(x,255-row)))/log1p(Double(maximum))*3
            let i = min(2,Int(level)), t = level-Double(i), a = colors[i], b = colors[i+1], start = (row*width+x)*4
            pixels[start] = UInt8(clamping:Int((a.0+(b.0-a.0)*t)*255)); pixels[start+1] = UInt8(clamping:Int((a.1+(b.1-a.1)*t)*255)); pixels[start+2] = UInt8(clamping:Int((a.2+(b.2-a.2)*t)*255)); pixels[start+3] = 255
        } }
        guard let provider = CGDataProvider(data:Data(pixels) as CFData) else { return nil }
        return CGImage(width:width,height:256,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)
    }
}

struct MagicDatabaseView:View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack { VStack(alignment:.leading,spacing:5) { Text("File signature database").font(.title2.weight(.semibold)); Text("\(FileMagic.rules.count) built-in magic rules, plus container and text identification.").font(.system(size:11)).foregroundStyle(.secondary) }; Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            TextField("Filter by format, MIME type, or category",text:$query).textFieldStyle(.roundedBorder)
            Table(FileMagic.rules.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.mime.localizedCaseInsensitiveContains(query) || $0.category.rawValue.localizedCaseInsensitiveContains(query) }) {
                TableColumn("Format",value:\.name).width(min:180,ideal:220)
                TableColumn("MIME type",value:\.mime).width(min:230,ideal:260)
                TableColumn("Offset") { Text("\($0.offset)").monospaced() }.width(50)
                TableColumn("Magic bytes") { Text(ByteFormatting.hex(Data($0.bytes))).font(.system(size:10,design:.monospaced)).help(ByteFormatting.hex(Data($0.bytes))) }.width(min:150,ideal:220)
            }
            Text("Identification uses bytes, not filename extensions. Signatures identify candidates; specialized parsers validate executable structure. MIME names include conventional x- types where no standard type exists.").font(.system(size:10)).foregroundStyle(.secondary)
        }.padding(24).frame(width:890,height:570)
    }
}
