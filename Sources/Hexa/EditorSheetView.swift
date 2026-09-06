import SwiftUI
import HexaCore

struct EditorSheetView: View {
    @ObservedObject var model: EditorModel
    let kind: EditorSheet
    @ObservedObject private var settings = EditorSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var offset = ""
    @State private var length = ""
    @State private var input = ""
    @State private var inputHex = true
    @State private var insertPattern = false
    @State private var transform = "Invert bits"
    @State private var numberType = "UInt32"
    @State private var validation: String?
    @FocusState private var focus: Bool
    private var title: String {
        switch kind { case .goTo: return "Go to offset"; case .selectRange: return "Select a range"; case .editBytes: return "Edit bytes"; case .fill: return "Fill or insert a pattern"; case .transform: return "Transform selection"; case .preferences: return "Make Hexa yours"; case .numeric: return "Write a numeric value" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: kind == .preferences ? "slider.horizontal.3" : "square.and.pencil").font(.system(size: 24, weight: .light)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 20, weight: .semibold)); Text(kind == .preferences ? "A workspace that feels right." : model.displayName).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Divider()
            fields
            if let validation { Label(validation, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if kind != .preferences { Text("Edits can be undone with ⌘Z.").font(.system(size: 10)).foregroundStyle(.tertiary) }
                Spacer()
                Button(kind == .preferences ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if kind != .preferences { Button(actionTitle) { apply() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
            }
        }.padding(26).frame(width: kind == .editBytes ? 560 : 460)
        .onAppear {
            offset = "0x" + String(model.caret, radix: 16).uppercased(); length = String(model.selection.count)
            if kind == .editBytes { input = ByteFormatting.hex(model.store.data(in: model.caret..<(model.caret + min(4096, model.selection.count)))) }
            if kind == .fill { input = "00"; if model.selection.isEmpty { insertPattern = true; length = "16" } }
            if kind == .transform { input = "FF" }
            if kind == .numeric { input = "0" }
            focus = true
        }
    }
    @ViewBuilder private var fields: some View {
        switch kind {
        case .goTo, .selectRange:
            labeled("Offset") { TextField("0x100 or 256", text: $offset).focused($focus).textFieldStyle(.roundedBorder) }
            if kind == .selectRange { labeled("Length in bytes") { TextField("16", text: $length).textFieldStyle(.roundedBorder) } }
            Text("Use decimal or 0x-prefixed hexadecimal. An offset starting with + or - is relative to the current position.").font(.system(size: 11)).foregroundStyle(.secondary)
        case .editBytes:
            Picker("Format", selection: $inputHex) { Text("Hexadecimal").tag(true); Text("Text · \(model.encoding.rawValue)").tag(false) }.pickerStyle(.segmented).labelsHidden()
            TextEditor(text: $input).font(.system(size: 12, design: .monospaced)).focused($focus).frame(height: 170).padding(7).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
            Text("Replaces the selected \(model.selection.count.formatted()) bytes. At an empty selection, inserts bytes. Hex accepts spaces, commas, and 0x prefixes. Preview is limited to 4 KiB; replacing affects the entire selection.").font(.system(size: 11)).foregroundStyle(.secondary)
        case .fill:
            labeled("Repeating hex pattern") { TextField("00 or DE AD BE EF", text: $input).textFieldStyle(.roundedBorder).focused($focus) }
            Toggle("Insert at offset instead of filling selection", isOn: $insertPattern)
            if insertPattern { labeled("Number of bytes") { TextField("16", text: $length).textFieldStyle(.roundedBorder) } }
            Text(insertPattern ? "Inserts the requested number of bytes at 0x\(String(model.caret, radix: 16).uppercased())." : "Fills exactly \(model.selection.count.formatted()) selected bytes; file size stays the same.").font(.system(size: 11)).foregroundStyle(.secondary)
        case .transform:
            Picker("Operation", selection: $transform) { ForEach(["Invert bits", "XOR with pattern", "Reverse bytes", "Swap 16-bit byte order", "Swap 32-bit byte order", "Swap 64-bit byte order"], id: \.self) { Text($0) } }
            if transform == "XOR with pattern" { labeled("Hex XOR key") { TextField("FF", text: $input).textFieldStyle(.roundedBorder).focused($focus) } }
            Text("Applies to \(model.selection.count.formatted()) selected bytes as a single undoable edit. Byte-order swaps require a selection divisible by the word size.").font(.system(size: 11)).foregroundStyle(.secondary)
        case .numeric:
            Picker("Type", selection: $numberType) { ForEach(["UInt8", "Int8", "UInt16", "Int16", "UInt32", "Int32", "UInt64", "Int64", "Float32", "Float64"], id: \.self) { Text($0) } }
            labeled("Value") { TextField("0", text: $input).textFieldStyle(.roundedBorder).focused($focus) }
            Picker("Byte order", selection: $model.littleEndian) { Text("Little endian").tag(true); Text("Big endian").tag(false) }.pickerStyle(.segmented).labelsHidden()
            Text("Writes at the current offset using \(model.editMode.rawValue.lowercased()) mode. A selection of multiple bytes is replaced. Integer input is decimal; unsigned values also accept 0x hexadecimal.").font(.system(size: 11)).foregroundStyle(.secondary)
        case .preferences:
            Picker("Appearance", selection: $settings.appearance) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) } }
            Picker("Bytes per row", selection: $settings.columns) { Text("Automatic").tag(0); ForEach([8, 16, 32], id: \.self) { Text("\($0)").tag($0) } }
            Picker("Group bytes", selection: $settings.group) { ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)").tag($0) } }
            HStack { Text("Font size"); Slider(value: $settings.fontSize, in: 10...20, step: 1); Text("\(Int(settings.fontSize)) pt").monospacedDigit().frame(width: 40) }
            Toggle("Decimal offsets", isOn: $settings.decimalOffsets)
            Toggle("Color bytes by category", isOn: $settings.colorBytes)
            Text("Zeroes are muted, nonprinting bytes are teal, and FF is orange. Orange underlines mark edits since the file was opened.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var actionTitle: String { kind == .goTo ? "Go" : kind == .selectRange ? "Select" : "Apply" }
    private func labeled<V: View>(_ label: String, @ViewBuilder content: () -> V) -> some View { VStack(alignment: .leading, spacing: 7) { Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary); content() } }
    private func apply() {
        do {
            switch kind {
            case .goTo, .selectRange:
                let start = try BytePattern.parseOffset(offset, relativeTo: model.caret)
                guard start <= model.count else { throw HexaError.message("Offset must be between 0 and \(model.count.formatted()).") }
                let count = kind == .selectRange ? try BytePattern.parseOffset(length) : min(1, model.count - start)
                guard count <= model.count - start else { throw HexaError.message("The selection extends beyond the end of the file.") }
                model.select(start..<(start + count))
            case .editBytes:
                let data = inputHex ? Data(try BytePattern(hex: input, wildcards: false).values) : try model.encoding.encode(input)
                guard data.count <= 16 * 1024 * 1024 else { throw HexaError.message("Use up to 16 MiB in the byte editor.") }
                model.edit(model.selection, data: data, name: "Edit Bytes", selectInserted: true)
            case .fill:
                let pattern = try BytePattern(hex: input, wildcards: false).values
                guard !pattern.isEmpty else { throw HexaError.message("Enter at least one byte for the pattern.") }
                let count = insertPattern ? try BytePattern.parseOffset(length) : model.selection.count
                guard count > 0, count <= 64 * 1024 * 1024 else { throw HexaError.message("Choose between 1 byte and 64 MiB per fill operation.") }
                var data = Data(count: count)
                data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in for i in 0..<count { bytes[i] = pattern[i % pattern.count] } }
                model.edit(insertPattern ? model.caret..<model.caret : model.selection, data: data, name: insertPattern ? "Insert Pattern" : "Fill Selection", selectInserted: true)
            case .transform:
                guard !model.selection.isEmpty, model.selection.count <= 64 * 1024 * 1024 else { throw HexaError.message("Select between 1 byte and 64 MiB to transform.") }
                var data = Array(model.selectedData)
                if transform == "Invert bits" { data = data.map { ~$0 } }
                else if transform == "Reverse bytes" { data.reverse() }
                else if transform == "XOR with pattern" {
                    let key = try BytePattern(hex: input, wildcards: false).values
                    guard !key.isEmpty else { throw HexaError.message("Enter an XOR key.") }
                    for i in data.indices { data[i] ^= key[i % key.count] }
                } else {
                    let width = transform.contains("16") ? 2 : transform.contains("32") ? 4 : 8
                    guard data.count.isMultiple(of: width) else { throw HexaError.message("Select a multiple of \(width) bytes for this operation.") }
                    for start in stride(from: 0, to: data.count, by: width) { data.replaceSubrange(start..<start + width, with: data[start..<start + width].reversed()) }
                }
                model.edit(model.selection, data: Data(data), name: transform, selectInserted: true)
            case .numeric:
                let width = numberType.contains("64") ? 8 : numberType.contains("32") ? 4 : numberType.contains("16") ? 2 : 1
                let value: UInt64, text = input.trimmingCharacters(in: .whitespacesAndNewlines)
                if numberType == "Float32", let number = Float(text) { value = UInt64(number.bitPattern) }
                else if numberType == "Float64", let number = Double(text) { value = number.bitPattern }
                else if numberType.hasPrefix("UInt") {
                    let hex = text.lowercased().hasPrefix("0x")
                    guard let number = UInt64(hex ? String(text.dropFirst(2)) : text, radix: hex ? 16 : 10), width == 8 || number < (UInt64(1) << (width * 8)) else { throw HexaError.message("Enter a valid \(numberType) value.") }
                    value = number
                } else if numberType.hasPrefix("Int"), let number = Int64(text), width == 8 || (number >= -(Int64(1) << (width * 8 - 1)) && number < (Int64(1) << (width * 8 - 1))) { value = UInt64(bitPattern: number) }
                else { throw HexaError.message("Enter a valid \(numberType) value.") }
                var bytes = (0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
                if !model.littleEndian { bytes.reverse() }
                model.insert(Data(bytes), name: "Write \(numberType)")
            case .preferences: break
            }
            dismiss()
        } catch { validation = error.localizedDescription }
    }
}
