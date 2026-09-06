import AppKit
import SwiftUI
import HexaCore

struct HexGrid: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    @ObservedObject var settings: EditorSettings
    func makeNSView(context: Context) -> GridContainer { GridContainer(model: model, settings: settings) }
    func updateNSView(_ view: GridContainer, context: Context) { view.refresh() }
}

@MainActor final class GridContainer: NSView {
    let scroll = NSScrollView()
    let grid: ByteGridView
    let header: GridHeader
    private var observer: NSObjectProtocol?
    init(model: EditorModel, settings: EditorSettings) {
        grid = ByteGridView(model: model, settings: settings); header = GridHeader(grid: grid)
        super.init(frame: .zero)
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
        scroll.documentView = grid
        addSubview(scroll); addSubview(header)
        scroll.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.header.needsDisplay = true }
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: bounds.height - 31, width: bounds.width, height: 31)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 31))
        refresh()
    }
    func refresh() {
        grid.updateGeometry(viewport: scroll.contentSize)
        header.needsDisplay = true; grid.needsDisplay = true
        if grid.lastReveal != grid.model.revealToken {
            grid.lastReveal = grid.model.revealToken
            let row = grid.model.caret / grid.columns
            let rect = NSRect(x: grid.hexX, y: CGFloat(row) * grid.rowHeight, width: min(100, scroll.contentSize.width), height: grid.rowHeight)
            grid.scrollToVisible(rect)
            // Searches and inspector navigation do not steal keyboard focus from text fields.
        }
    }
}

@MainActor final class GridHeader: NSView {
    unowned let grid: ByteGridView
    init(grid: ByteGridView) { self.grid = grid; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let shift = grid.enclosingScrollView?.contentView.bounds.origin.x ?? 0
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        func label(_ text: String, _ x: CGFloat, color: NSColor = .secondaryLabelColor) {
            (text as NSString).draw(at: NSPoint(x: x - shift, y: 9), withAttributes: [.font: font, .foregroundColor: color])
        }
        label(grid.settings.decimalOffsets ? "OFFSET · DEC" : "OFFSET · HEX", 20)
        for i in 0..<grid.columns { label(String(format: "%02X", i), grid.x(for: i) + 2) }
        label("TEXT", grid.textX)
        NSColor.separatorColor.withAlphaComponent(0.5).setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

@MainActor final class ByteGridView: NSView {
    let model: EditorModel
    let settings: EditorSettings
    var columns = 16
    var rowHeight: CGFloat = 25
    var charWidth: CGFloat = 8
    var cellWidth: CGFloat = 25
    var hexX: CGFloat = 110
    var textX: CGFloat = 565
    var lastReveal = -1
    private var dragAnchor = 0
    private var keyboardHead: Int?
    private var dragPane: BytePane = .hex
    private var font: NSFont { NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    init(model: EditorModel, settings: EditorSettings) {
        self.model = model; self.settings = settings
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true); setAccessibilityRole(.textArea)
        setAccessibilityLabel("Hexadecimal byte editor")
        setAccessibilityHelp("Use arrow keys to navigate, Shift and arrows to select, Tab to switch hex and text, and type to edit. Use the data inspector for accessible selected byte values.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { model.pendingNibble = nil; needsDisplay = true; return true }

    func x(for column: Int) -> CGFloat { hexX + CGFloat(column) * cellWidth + CGFloat(column / max(1, settings.group)) * 9 }
    func updateGeometry(viewport: NSSize) {
        charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        cellWidth = charWidth * 2 + 9; rowHeight = ceil(settings.fontSize + 12)
        let digits = max(8, String(model.count, radix: settings.decimalOffsets ? 10 : 16).count)
        hexX = max(100, CGFloat(digits) * charWidth + 38)
        if settings.columns == 0 {
            columns = [32, 16, 8].first { candidate in
                hexX + CGFloat(candidate) * (cellWidth + charWidth + 2) + CGFloat(candidate / max(settings.group, 1)) * 9 + 50 < viewport.width
            } ?? 8
        } else { columns = settings.columns }
        textX = x(for: columns) + 21
        let width = textX + CGFloat(columns) * (charWidth + 2) + 24
        let rows = model.count / columns + 1
        let height = CGFloat(rows) * rowHeight + 20
        setFrameSize(NSSize(width: max(width, viewport.width), height: max(height, viewport.height)))
        let preview = model.store.data(in: model.caret..<(model.caret + min(16, model.count - model.caret)))
        setAccessibilityValue("Offset \(model.caret), \(model.selection.count) bytes selected. \(ByteFormatting.hex(preview)). \(model.editMode.rawValue) mode.")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill(); dirtyRect.fill()
        let firstRow = max(0, Int(dirtyRect.minY / rowHeight)), lastRow = min(model.count / columns, Int(dirtyRect.maxY / rowHeight))
        guard firstRow <= lastRow else { return }
        let selected = model.selection
        let focused = window?.firstResponder === self
        let activeColor = focused ? NSColor.controlAccentColor : NSColor.unemphasizedSelectedContentBackgroundColor
        let baseAttributes: [NSAttributedString.Key: Any] = [.font: font]
        let addressFont = NSFont.monospacedSystemFont(ofSize: max(10, settings.fontSize - 1), weight: .regular)
        let matchRanges = relevantRanges(model.searchResults, from: firstRow * columns, to: min(model.count, (lastRow + 1) * columns))
        let diffRanges = relevantRanges(model.differences?.ranges ?? [], from: firstRow * columns, to: min(model.count, (lastRow + 1) * columns))
        let structureRegions = model.showStructureColors ? (model.structure?.regions ?? []).filter { $0.kind != .group && $0.range.lowerBound < min(model.count,(lastRow+1)*columns) && $0.range.upperBound > firstRow*columns }.sorted { $0.range.count < $1.range.count } : []
        for row in firstRow...lastRow {
            let offset = row * columns, y = CGFloat(row) * rowHeight
            if row % 2 == 1 { NSColor.labelColor.withAlphaComponent(0.022).setFill(); NSRect(x: 0, y: y, width: bounds.width, height: rowHeight).fill() }
            if offset <= model.caret, model.caret < offset + columns {
                NSColor.controlAccentColor.withAlphaComponent(0.035).setFill(); NSRect(x: 0, y: y, width: bounds.width, height: rowHeight).fill()
            }
            let address = settings.decimalOffsets ? String(format: "%08lld", Int64(offset)) : String(format: "%08llX", UInt64(offset))
            (address as NSString).draw(at: NSPoint(x: 20, y: y + (rowHeight - addressFont.pointSize) / 2 - 1), withAttributes: [.font: addressFont, .foregroundColor: NSColor.tertiaryLabelColor])
            if model.bookmarks.contains(where: { $0.offset >= offset && $0.offset < offset + columns }) {
                NSColor.systemOrange.setFill(); NSBezierPath(roundedRect: NSRect(x: 7, y: y + rowHeight / 2 - 3, width: 4, height: 6), xRadius: 2, yRadius: 2).fill()
            }
            let rowEnd = min(model.count, offset + columns)
            let bytes = Array(model.store.data(in: offset..<rowEnd))
            let edited = model.store.editedRanges(in: offset..<rowEnd)
            for (column, byte) in bytes.enumerated() {
                let position = offset + column
                let hexRect = NSRect(x: x(for: column) - 2, y: y + 2, width: cellWidth - 1, height: rowHeight - 4)
                let textRect = NSRect(x: textX + CGFloat(column) * (charWidth + 2) - 1, y: y + 2, width: charWidth + 3, height: rowHeight - 4)
                let isSelected = selected.contains(position), isMatch = matchRanges.contains { $0.contains(position) }, isDifferent = diffRanges.contains { $0.contains(position) }
                let structureRegion = structureRegions.first { $0.range.contains(position) }
                for (pane, rect) in [(BytePane.hex, hexRect), (BytePane.text, textRect)] {
                    if isSelected { (pane == model.activePane ? activeColor : NSColor.controlAccentColor.withAlphaComponent(0.15)).setFill(); NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill() }
                    else if isDifferent { NSColor.systemPink.withAlphaComponent(0.14).setFill(); NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill() }
                    else if isMatch { NSColor.systemYellow.withAlphaComponent(0.28).setFill(); NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill() }
                    else if let region = structureRegion { StructurePalette.nsColor(region.colorIndex).withAlphaComponent(region.kind == .field ? 0.15:0.07).setFill(); NSBezierPath(roundedRect:rect,xRadius:3,yRadius:3).fill() }
                }
                let color: NSColor
                if !settings.colorBytes { color = .labelColor }
                else if byte == 0 { color = .tertiaryLabelColor }
                else if byte == 255 { color = .systemOrange }
                else if (32...126).contains(byte) { color = .labelColor }
                else { color = .systemTeal }
                var hexAttributes = baseAttributes, textAttributes = baseAttributes
                hexAttributes[.foregroundColor] = isSelected && model.activePane == .hex && focused ? NSColor.white : color
                textAttributes[.foregroundColor] = isSelected && model.activePane == .text && focused ? NSColor.white : (32...126).contains(byte) ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
                let text = displayCharacter(byte)
                let hex = model.pendingNibble.map { position == model.caret ? String(format: "%X·", $0) : String(format: "%02X", byte) } ?? String(format: "%02X", byte)
                (hex as NSString).draw(at: NSPoint(x: x(for: column) + 1, y: y + (rowHeight - settings.fontSize) / 2 - 1), withAttributes: hexAttributes)
                (text as NSString).draw(at: NSPoint(x: textRect.minX + 1, y: y + (rowHeight - settings.fontSize) / 2 - 1), withAttributes: textAttributes)
                if edited.contains(where: { $0.contains(position) }) {
                    NSColor.systemOrange.withAlphaComponent(0.8).setFill(); NSRect(x: hexRect.minX + 4, y: hexRect.maxY - 1, width: hexRect.width - 8, height: 1).fill()
                }
            }
            if model.caret == model.count, model.count / columns == row {
                let column = model.count % columns
                let caretX = model.activePane == .hex ? x(for: column) : textX + CGFloat(column) * (charWidth + 2)
                NSColor.controlAccentColor.setFill(); NSRect(x: caretX, y: y + 4, width: 2, height: rowHeight - 8).fill()
                if let nibble = model.pendingNibble { (String(format: "%X·", nibble) as NSString).draw(at: NSPoint(x: caretX + 3, y: y + 5), withAttributes: [.font: font, .foregroundColor: NSColor.controlAccentColor]) }
            }
        }
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: hexX - 14, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        NSRect(x: textX - 14, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    }

    private func displayCharacter(_ byte: UInt8) -> String {
        if (32...126).contains(byte) { return String(UnicodeScalar(byte)) }
        if model.encoding == .latin1, byte >= 160 { return String(UnicodeScalar(byte)) }
        return "·"
    }
    private func relevantRanges(_ ranges: [Range<Int>], from start: Int, to end: Int) -> [Range<Int>] {
        var low = 0, high = ranges.count
        while low < high { let mid = (low + high) / 2; if ranges[mid].upperBound <= start { low = mid + 1 } else { high = mid } }
        var result: [Range<Int>] = []
        while low < ranges.count, ranges[low].lowerBound < end { result.append(ranges[low]); low += 1 }
        return result
    }
    private func hit(_ event: NSEvent) -> (Int, BytePane) {
        let point = convert(event.locationInWindow, from: nil)
        let row = max(0, Int(point.y / rowHeight)), pane: BytePane = point.x >= textX - 10 ? .text : .hex
        let column: Int
        if pane == .text { column = max(0, min(columns - 1, Int((point.x - textX) / (charWidth + 2)))) }
        else { column = (0..<columns).min(by: { abs(x(for: $0) + charWidth - point.x) < abs(x(for: $1) + charWidth - point.x) }) ?? 0 }
        return (min(model.count, row * columns + column), pane)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let (offset, pane) = hit(event); model.activePane = pane; dragPane = pane; keyboardHead = nil
        if event.modifierFlags.contains(.shift) { model.move(to: offset, extending: true) }
        else { dragAnchor = offset; model.select(offset..<min(model.count, offset + 1), reveal: false) }
        if event.clickCount == 2 { let start = offset / columns * columns; model.select(start..<min(model.count, start + columns), reveal: false) }
        if event.clickCount >= 3 { model.selectAll() }
    }
    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        let (offset, _) = hit(event)
        model.select(min(dragAnchor, offset)..<min(model.count, max(dragAnchor, offset) + 1), reveal: false, resetAnchor: false)
    }
    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift), command = event.modifierFlags.contains(.command)
        let current = keyboardHead ?? model.caret
        var destination: Int?
        switch event.keyCode {
        case 123: destination = command ? current / columns * columns : current - 1
        case 124: destination = command ? min(model.count, current / columns * columns + columns - 1) : current + 1
        case 125: destination = command ? model.count : current + columns
        case 126: destination = command ? 0 : current - columns
        case 115: destination = 0
        case 119: destination = model.count
        case 116: destination = current - max(1, Int(visibleRect.height / rowHeight) - 1) * columns
        case 121: destination = current + max(1, Int(visibleRect.height / rowHeight) - 1) * columns
        case 48: model.activePane = model.activePane == .hex ? .text : .hex; model.pendingNibble = nil
        case 51: model.delete(backwards: true)
        case 117: model.delete()
        case 53: model.pendingNibble = nil; model.status = "Ready"
        case 36, 76: model.activePane = model.activePane == .hex ? .text : .hex
        default:
            guard !command, !event.modifierFlags.contains(.control), let characters = event.characters, !characters.isEmpty else { super.keyDown(with: event); return }
            if model.activePane == .hex { for character in characters { model.typeHex(character) } }
            else { model.typeText(characters) }
        }
        if let destination {
            let value = max(0, min(model.count, destination)); model.move(to: value, extending: shift); keyboardHead = shift ? value : nil
        } else { keyboardHead = nil }
    }
    @objc func copy(_ sender: Any?) { model.copy(format: model.activePane == .hex ? "hex" : "text") }
    @objc func cut(_ sender: Any?) { model.cut() }
    @objc func paste(_ sender: Any?) { model.paste() }
    override func selectAll(_ sender: Any?) { model.selectAll() }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, selector) in [("Copy Hex", #selector(copyHex)), ("Copy Text", #selector(copyText)), ("Copy Hex Dump", #selector(copyDump)), ("Paste", #selector(paste(_:))), ("Delete", #selector(deleteSelection)), ("Add Bookmark", #selector(bookmarkSelection))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc private func copyHex() { model.copy() }
    @objc private func copyText() { model.copy(format: "text") }
    @objc private func copyDump() { model.copy(format: "dump") }
    @objc private func deleteSelection() { model.delete() }
    @objc private func bookmarkSelection() { model.addBookmark() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        urls.forEach { AppDelegate.shared.open($0) }; return true
    }
}
