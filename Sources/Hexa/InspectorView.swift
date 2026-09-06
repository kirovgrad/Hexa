import SwiftUI
import HexaCore

struct InspectorView: View {
    @ObservedObject var model: EditorModel
    private var available: Data { model.store.data(in: model.caret..<(model.caret + min(256, model.count - model.caret))) }
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.inspectorTab) { Text("Inspector").tag(0); Text("Analysis").tag(1) }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Inspector panel").padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if model.inspectorTab == 0 { inspector } else { analysis }
                }.padding(.horizontal, 19).padding(.bottom, 22)
            }
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    @ViewBuilder private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("SELECTION", icon: "scope")
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(model.selection.count.formatted()).font(.system(size: 30, weight: .light, design: .rounded))
                Text(model.selection.count == 1 ? "byte" : "bytes").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button { model.sheet = .selectRange } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Select range")
            }
            HStack { Text("Offset"); Spacer(); Text("0x\(String(model.caret, radix: 16).uppercased())").monospaced() }.font(.system(size: 11)).foregroundStyle(.secondary)
            if model.selection.count > 1 { valueRow("Through", "0x\(String(model.selection.upperBound - 1, radix: 16).uppercased())") }
        }
        Divider()
        VStack(alignment: .leading, spacing: 13) {
            sectionTitle("DATA INTERPRETATION", icon: "slider.horizontal.3")
            Picker("Byte order", selection: $model.littleEndian) { Text("Little endian").tag(true); Text("Big endian").tag(false) }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
            Text("Values begin at the selected offset.").font(.system(size: 10)).foregroundStyle(.tertiary)
            VStack(spacing: 0) {
                integerRow("UInt8", width: 1, signed: false)
                integerRow("Int8", width: 1, signed: true)
                integerRow("UInt16", width: 2, signed: false)
                integerRow("Int16", width: 2, signed: true)
                integerRow("UInt32", width: 4, signed: false)
                integerRow("Int32", width: 4, signed: true)
                integerRow("UInt64", width: 8, signed: false)
                integerRow("Int64", width: 8, signed: true)
                valueRow("Float32", floatValue(width: 4))
                valueRow("Float64", floatValue(width: 8))
            }
            Button("Write Numeric Value…") { model.sheet = .numeric }.font(.system(size: 11)).disabled(!model.canEdit)
        }
        Divider()
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("BITS", icon: "switch.2")
            HStack(spacing: 4) {
                ForEach((0..<8).reversed(), id: \.self) { bit in
                    let enabled = (available.first ?? 0) & (1 << bit) != 0
                    Button {
                        if let byte = available.first { model.edit(model.caret..<(model.caret + 1), data: Data([byte ^ (1 << bit)]), name: "Toggle Bit", selectInserted: true) }
                    } label: {
                        VStack(spacing: 6) {
                            Text(enabled ? "1" : "0").font(.system(size: 13, weight: .medium, design: .monospaced)).frame(maxWidth: .infinity).frame(height: 28)
                                .background(enabled ? Color.blue.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(enabled ? .blue : .secondary)
                            Text("\(bit)").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                    }.buttonStyle(.plain).disabled(!model.canEdit || available.isEmpty).help("Toggle bit \(bit)")
                }
            }
            if let byte = available.first { valueRow("Octal", String(byte, radix: 8)); valueRow("Hex", String(format: "0x%02X", byte)) }
        }
        Divider()
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("TEXT PREVIEW", icon: "textformat")
            Picker("Encoding", selection: $model.encoding) { ForEach(TextEncoding.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().controlSize(.small)
            Text(textPreview).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 45, alignment: .topLeading).padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            Text("Up to 256 bytes from the offset. The grid displays one character per byte; multibyte text is decoded here.").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        if available.count >= 4 {
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("UNIX TIME · UTC", icon: "clock")
                Text(timestamp).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Signed 32-bit seconds since 1970.").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        if let other = model.comparison {
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("COMPARISON BYTES", icon: "square.split.2x1")
                Text(model.comparisonName).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(model.caret >= other.count ? "End of comparison file" : ByteFormatting.hex(other.data(in: model.caret..<(model.caret + min(16, other.count - model.caret)))))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Text("At the same offset in the other file.").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }
    @ViewBuilder private var analysis: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("FILE ANALYSIS", icon: "waveform.path")
            Text("Understand the bytes.").font(.system(size: 19, weight: .medium))
            Text("Checksums, byte distribution, and information entropy.").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack { Button("Analyze File") { model.analyze() }; Button("Selection") { model.analyze(selectionOnly: true) }.disabled(model.selection.isEmpty) }.controlSize(.small).disabled(model.isBusy)
        }
        if let report = model.analysis {
            Divider()
            VStack(alignment: .leading, spacing: 13) {
                sectionTitle("BYTE DISTRIBUTION", icon: "chart.bar.xaxis")
                HistogramView(values: report.histogram).frame(height: 90)
                HStack { Text("00"); Spacer(); Text("FF") }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                HStack(alignment: .firstTextBaseline) { Text(String(format: "%.4f", report.entropy)).font(.system(size: 29, weight: .light, design: .rounded)); Text("bits / byte").font(.system(size: 11)).foregroundStyle(.secondary) }
                Text("Shannon entropy · 0 to 8").font(.system(size: 10)).foregroundStyle(.tertiary)
                valueRow("Analyzed", "\(report.count.formatted()) bytes")
                valueRow("Printable ASCII", percent(report.printable, of: report.count))
                valueRow("Zero bytes", percent(report.zeroes, of: report.count))
                if let range = model.analysisRange { valueRow("Start", "0x\(String(range.lowerBound, radix: 16).uppercased())") }
            }
            Divider()
            VStack(alignment: .leading, spacing: 17) {
                sectionTitle("CHECKSUMS", icon: "number")
                hash("SHA-256", report.sha256)
                hash("SHA-512", report.sha512)
                hash("MD5", report.md5)
                hash("CRC-32 / ISO-HDLC", report.crc32)
                Text("MD5 and CRC-32 are compatibility checksums, not security checks.").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        } else {
            VStack(spacing: 16) {
                Image(systemName: "chart.bar.doc.horizontal").font(.system(size: 41, weight: .ultraLight)).foregroundStyle(.tertiary)
                Text("Run an analysis to reveal the file’s distribution and fingerprints.").font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(.vertical, 40)
        }
    }
    private func sectionTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) { Image(systemName: icon).font(.system(size: 10)); Text(title).font(.system(size: 9, weight: .semibold)).tracking(1) }.foregroundStyle(.secondary)
    }
    private func integerRow(_ name: String, width: Int, signed: Bool) -> some View {
        let data = Data(available.prefix(width))
        let value = data.count < width ? "—" : signed ? ByteAnalysis.signed(data, littleEndian: model.littleEndian).map(String.init) ?? "—" : ByteAnalysis.unsigned(data, littleEndian: model.littleEndian).map(String.init) ?? "—"
        return valueRow(name, value)
    }
    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(label).foregroundStyle(.secondary); Spacer(minLength: 5); Text(value).font(.system(size: 10, design: .monospaced)).foregroundStyle(.primary).textSelection(.enabled).lineLimit(2) }.font(.system(size: 10)).padding(.vertical, 5)
    }
    private func floatValue(width: Int) -> String {
        guard available.count >= width, let value = ByteAnalysis.unsigned(Data(available.prefix(width)), littleEndian: model.littleEndian) else { return "—" }
        return width == 4 ? String(Float(bitPattern: UInt32(value))) : String(Double(bitPattern: value))
    }
    private var textPreview: String {
        guard !available.isEmpty else { return "End of file" }
        let data = model.selection.count > 1 ? Data(available.prefix(model.selection.count)) : available
        let decoded = String(data: data, encoding: model.encoding.foundation) ?? (model.encoding == .utf8 ? String(decoding: data, as: UTF8.self) : "Cannot decode these bytes with \(model.encoding.rawValue).")
        return decoded.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" ? "·" : String($0) }.joined()
    }
    private var timestamp: String {
        let value = ByteAnalysis.signed(Data(available.prefix(4)), littleEndian: model.littleEndian) ?? 0
        let formatter = ISO8601DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date(timeIntervalSince1970: Double(value)))
    }
    private func percent(_ value: Int, of count: Int) -> String { String(format: "%.2f%%", count == 0 ? 0 : Double(value) / Double(count) * 100) }
    private func hash(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).font(.system(size: 10)).help("Copy \(title)")
            }
            Text(value).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct HistogramView: View {
    let values: [Int]
    var body: some View {
        Canvas { context, size in
            let maximum = max(1, values.max() ?? 1), width = size.width / CGFloat(values.count)
            for (i, value) in values.enumerated() {
                let height = max(1, CGFloat(value) / CGFloat(maximum) * size.height)
                context.fill(Path(CGRect(x: CGFloat(i) * width, y: size.height - height, width: max(0.5, width - 0.3), height: height)), with: .color(.blue.opacity(0.35 + Double(value) / Double(maximum) * 0.6)))
            }
        }.accessibilityLabel("Byte frequency histogram, from byte 0 to byte 255")
    }
}
