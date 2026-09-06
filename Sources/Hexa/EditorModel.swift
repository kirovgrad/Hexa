import AppKit
import SwiftUI
import HexaCore

enum EditMode: String, CaseIterable { case overwrite = "Overwrite", insert = "Insert" }
enum BytePane { case hex, text }
enum WorkspaceTab: String, CaseIterable { case bytes = "Bytes", structure = "Structure", analysis = "Analysis" }
enum SidebarTab: String, CaseIterable { case bookmarks = "Bookmarks", search = "Search", differences = "Compare", strings = "Strings" }
enum EditorSheet: String, Identifiable { case goTo, selectRange, editBytes, fill, transform, preferences, numeric; var id: String { rawValue } }
struct Bookmark: Identifiable, Codable, Equatable { let id: UUID; var offset: Int; var length: Int; var name: String }

@MainActor final class EditorSettings: ObservableObject {
    static let shared = EditorSettings()
    @Published var columns: Int = UserDefaults.standard.object(forKey: "columns") as? Int ?? 16 { didSet { UserDefaults.standard.set(columns, forKey: "columns") } }
    @Published var group: Int = UserDefaults.standard.object(forKey: "group") as? Int ?? 4 { didSet { UserDefaults.standard.set(group, forKey: "group") } }
    @Published var fontSize: Double = UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 12 { didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") } }
    @Published var decimalOffsets = UserDefaults.standard.bool(forKey: "decimalOffsets") { didSet { UserDefaults.standard.set(decimalOffsets, forKey: "decimalOffsets") } }
    @Published var colorBytes = UserDefaults.standard.object(forKey: "colorBytes") as? Bool ?? true { didSet { UserDefaults.standard.set(colorBytes, forKey: "colorBytes") } }
    @Published var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "System" { didSet { UserDefaults.standard.set(appearance, forKey: "appearance"); applyAppearance() } }
    func applyAppearance() { NSApp.appearance = appearance == "System" ? nil : NSAppearance(named: appearance == "Dark" ? .darkAqua : .aqua) }
}

@MainActor final class EditorModel: ObservableObject {
    @Published private(set) var store = ByteStore()
    @Published private(set) var selection: Range<Int> = 0..<0
    @Published private(set) var version = UUID()
    private var savedVersion = UUID()
    @Published var fileURL: URL?
    @Published var displayName = "Untitled"
    @Published var isSample = false
    @Published var isReadOnly = false
    @Published var editMode: EditMode = .overwrite
    @Published var activePane: BytePane = .hex
    @Published var pendingNibble: UInt8?
    @Published var showSidebar = true
    @Published var showInspector = true
    @Published var showFind = false
    @Published var workspaceTab: WorkspaceTab = .bytes
    @Published var parserFormat: BinaryFormat = .automatic
    @Published var showStructureColors = false
    @Published private(set) var structure: StructureReport?
    @Published private(set) var fileIdentity = FileMagic.identify(ByteStore())
    @Published private(set) var selectedStructureNode: BinaryNode?
    @Published var sidebarTab: SidebarTab = .bookmarks
    @Published var inspectorTab = 0
    @Published var littleEndian = true
    @Published var encoding: TextEncoding = .utf8
    @Published var bookmarks: [Bookmark] = []
    @Published var query = ""
    @Published var replacement = ""
    @Published var searchHex = true
    @Published var searchSelectionOnly = false
    @Published private(set) var searchResults: [Range<Int>] = []
    @Published private(set) var searchTruncated = false
    @Published private(set) var searchIndex = -1
    @Published private(set) var searchHasRun = false
    @Published private(set) var analysis: AnalysisReport?
    @Published private(set) var analysisRange: Range<Int>?
    @Published private(set) var differences: DifferenceReport?
    @Published private(set) var comparison: ByteStore?
    @Published private(set) var comparisonName = ""
    @Published private(set) var foundStrings: [FoundString] = []
    @Published private(set) var stringsTruncated = false
    @Published private(set) var stringsHaveRun = false
    @Published var minimumStringLength = 4
    @Published private(set) var busyMessage: String?
    @Published private(set) var canCancelWork = true
    @Published var status = "Ready"
    @Published var errorMessage: String?
    @Published var sheet: EditorSheet?
    @Published var revealToken = 0
    let undoManager = UndoManager()
    weak var window: NSWindow?
    var onTitleChange: (() -> Void)?
    private var stamp: FileStamp?
    private var workTask: Task<Void, Never>?
    private var workID = UUID()
    private var selectionAnchor = 0
    var isDirty: Bool { version != savedVersion }
    var isBusy: Bool { busyMessage != nil }
    var canEdit: Bool { !isReadOnly && !isBusy }
    var count: Int { store.count }
    var caret: Int { selection.lowerBound }
    var selectedData: Data { store.data(in: selection) }

    init(sample: Bool = false) {
        savedVersion = version
        undoManager.groupsByEvent = false
        if sample, let url = Bundle.main.url(forResource: "Welcome", withExtension: "bin") ?? Bundle.module.url(forResource: "Welcome", withExtension: "bin"), let data = try? Data(contentsOf: url) {
            store = ByteStore(data); displayName = "Welcome.bin"; isSample = true
            selection = 0..<min(1, data.count)
            bookmarks = [Bookmark(id: UUID(), offset: 0, length: 4, name: "File signature"), Bookmark(id: UUID(), offset: 112, length: 256, name: "Byte spectrum")]
            fileIdentity = FileMagic.identify(store)
            structure = try? BinaryStructure.parse(store)
        }
    }

    func select(_ range: Range<Int>, reveal: Bool = true, resetAnchor: Bool = true) {
        let low = max(0, min(count, range.lowerBound)), high = max(0, min(count, range.upperBound))
        selection = low..<max(low, high)
        pendingNibble = nil
        if resetAnchor { selectionAnchor = low }
        if reveal { revealToken += 1 }
    }
    func move(to offset: Int, extending: Bool) {
        let target = max(0, min(count, offset))
        if extending { select(min(selectionAnchor, target)..<max(selectionAnchor, min(count, target + 1)), resetAnchor: false) }
        else { select(target..<min(count, target + 1)) }
    }
    func selectAll() { select(0..<count) }

    func load(_ url: URL) {
        runWork("Opening \(url.lastPathComponent)…", operation: {
            let before = try FileStamp(url: url)
            let store = try ByteStore.open(url)
            guard before == (try FileStamp(url: url)) else { throw HexaError.message("This file changed while opening. Please try again.") }
            return (store, before, try BinaryStructure.parse(store))
        }) { [weak self] value in
            guard let self else { return }
            self.store = value.0; self.stamp = value.1; self.fileURL = url; self.displayName = url.lastPathComponent
            self.isSample = false; self.isReadOnly = !FileManager.default.isWritableFile(atPath: url.path)
            self.version = UUID(); self.savedVersion = self.version; self.undoManager.removeAllActions()
            self.invalidateResults(); self.loadBookmarks(); self.select(0..<min(1, self.count))
            self.structure = value.2; self.fileIdentity = value.2.identity
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            self.status = "Opened \(self.count.formatted()) bytes"; self.onTitleChange?()
        }
    }

    private struct State { let store: ByteStore; let selection: Range<Int>; let version: UUID; let bookmarks: [Bookmark] }
    private var state: State { State(store: store, selection: selection, version: version, bookmarks: bookmarks) }
    private func restore(_ old: State, name: String) {
        let current = state
        undoManager.registerUndo(withTarget: self) { $0.restore(current, name: name) }
        undoManager.setActionName(name)
        store = old.store; version = old.version; bookmarks = old.bookmarks; select(old.selection)
        invalidateResults(); persistBookmarks(); onTitleChange?()
    }

    func edit(_ range: Range<Int>, data: Data, name: String, selectInserted: Bool = false) {
        guard canEdit else { NSSound.beep(); return }
        if range.count == data.count, store.data(in: range) == data {
            let target = range.lowerBound + data.count
            select(selectInserted ? range.lowerBound..<target : target..<min(count, target + 1))
            return
        }
        let before = state
        do {
            try store.replace(range, with: data)
            shiftBookmarks(replacing: range, insertedCount: data.count)
            version = UUID()
            undoManager.beginUndoGrouping()
            undoManager.registerUndo(withTarget: self) { $0.restore(before, name: name) }
            undoManager.setActionName(name); undoManager.endUndoGrouping()
            let target = range.lowerBound + data.count
            select(selectInserted ? range.lowerBound..<target : target..<min(count, target + 1))
            invalidateResults(); persistBookmarks(); status = name; onTitleChange?()
        } catch { showError(error) }
    }
    func typeHex(_ character: Character) {
        guard canEdit, let digit = character.hexDigitValue, digit < 16, character.isASCII else { NSSound.beep(); return }
        if let high = pendingNibble {
            let value = high << 4 | UInt8(digit)
            pendingNibble = nil
            let range = editMode == .insert && selection.count <= 1 ? caret..<caret : selection.isEmpty ? caret..<min(count, caret + 1) : selection
            edit(range, data: Data([value]), name: "Type Hex")
        } else { pendingNibble = UInt8(digit); status = "Enter the second hex digit · Esc to cancel" }
    }
    func typeText(_ text: String) {
        do { let data = try encoding.encode(text); insert(data, name: "Type Text", useMode: true) } catch { showError(error) }
    }
    func insert(_ data: Data, name: String, useMode: Bool = true) {
        let range: Range<Int>
        if selection.count > 1 { range = selection }
        else if useMode, editMode == .overwrite { range = caret..<(caret + min(data.count, count - caret)) }
        else { range = caret..<caret }
        edit(range, data: data, name: name)
    }
    func delete(backwards: Bool = false) {
        if pendingNibble != nil { pendingNibble = nil; status = "Ready"; return }
        if !selection.isEmpty { edit(selection, data: Data(), name: "Delete") }
        else if backwards, caret > 0 { edit((caret - 1)..<caret, data: Data(), name: "Delete") }
    }
    func undo() { guard canEdit else { return }; pendingNibble = nil; undoManager.undo() }
    func redo() { guard canEdit else { return }; pendingNibble = nil; undoManager.redo() }

    func copy(format: String = "hex") {
        guard !selection.isEmpty else { return }
        guard selection.count <= 16 * 1024 * 1024 else { errorMessage = "Clipboard operations are limited to 16 MiB. Use Export Selection for larger ranges."; return }
        let data = selectedData, text: String
        switch format {
        case "text": text = String(data: data, encoding: encoding.foundation) ?? String(decoding: data, as: UTF8.self)
        case "dump": text = ByteFormatting.dump(data, offset: caret)
        case "swift": text = "[" + data.map { String(format: "0x%02X", $0) }.joined(separator: ", ") + "]"
        case "base64": text = data.base64EncodedString()
        default: text = ByteFormatting.hex(data)
        }
        let pasteboard = NSPasteboard.general; pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType("com.hexa.bytes"))
        status = "Copied \(selection.count.formatted()) bytes"
    }
    func cut() { guard canEdit, !selection.isEmpty, selection.count <= 16 * 1024 * 1024 else { NSSound.beep(); return }; copy(); delete() }
    func paste(asText: Bool = false) {
        guard canEdit else { return }
        do {
            let pasteboard = NSPasteboard.general
            let data: Data
            if !asText, let bytes = pasteboard.data(forType: NSPasteboard.PasteboardType("com.hexa.bytes")) { data = bytes }
            else if let text = pasteboard.string(forType: .string) {
                data = asText || activePane == .text ? try encoding.encode(text) : Data(try BytePattern(hex: text, wildcards: false).values)
            } else { return }
            guard data.count <= 16 * 1024 * 1024 else { throw HexaError.message("Clipboard operations are limited to 16 MiB. Use Insert File for larger data.") }
            insert(data, name: "Paste")
        } catch { showError(error) }
    }

    func find() {
        workspaceTab = .bytes
        do {
            let pattern = searchHex ? try BytePattern(hex: query) : BytePattern(data: try encoding.encode(query))
            let snapshot = store, range = searchSelectionOnly ? selection : nil
            guard range?.isEmpty != true else { throw HexaError.message("Select a range before searching the selection.") }
            runWork("Searching…", operation: { try ByteSearch.find(in: snapshot, pattern: pattern, range: range) }) { [weak self] result in
                guard let self else { return }
                self.searchResults = result.ranges; self.searchTruncated = result.truncated; self.searchIndex = -1; self.searchHasRun = true
                self.sidebarTab = .search; self.showSidebar = true
                self.status = "\(result.ranges.count.formatted())\(result.truncated ? "+" : "") matches"
                self.nextMatch()
            }
        } catch { showError(error) }
    }
    func clearSearchResults() { if busyMessage == "Searching…" { cancelWork() }; searchResults = []; searchIndex = -1; searchTruncated = false; searchHasRun = false }
    func nextMatch(backwards: Bool = false) {
        guard !searchResults.isEmpty else { return }
        if searchIndex < 0 { searchIndex = backwards ? searchResults.count - 1 : 0 }
        else { searchIndex = (searchIndex + (backwards ? searchResults.count - 1 : 1)) % searchResults.count }
        showBytes(searchResults[searchIndex])
    }
    func selectMatch(_ index: Int) { guard searchResults.indices.contains(index) else { return }; searchIndex = index; select(searchResults[index]) }
    func replaceMatch() {
        guard canEdit else { return }
        do {
            guard searchResults.contains(selection) else { throw HexaError.message("Run a search and select a match before replacing.") }
            let data = searchHex ? Data(try BytePattern(hex: replacement, wildcards: false).values) : try encoding.encode(replacement)
            edit(selection, data: data, name: "Replace", selectInserted: true)
            find()
        } catch { showError(error) }
    }
    func replaceAll() {
        guard canEdit else { return }
        do {
            guard searchHasRun, !searchResults.isEmpty else { throw HexaError.message("Run a search before replacing all matches.") }
            guard !searchTruncated else { throw HexaError.message("Too many matches to replace safely. Narrow the search to a selection.") }
            let data = searchHex ? Data(try BytePattern(hex: replacement, wildcards: false).values) : try encoding.encode(replacement)
            var ranges: [Range<Int>] = [], end = -1
            for range in searchResults where range.lowerBound >= end { ranges.append(range); end = range.upperBound }
            let before = state, snapshot = store, replacements = ranges
            runWork("Replacing \(ranges.count.formatted()) matches…", operation: {
                var result = snapshot
                try result.replaceAll(replacements, with: data)
                return result
            }) { [weak self] result in
                guard let self else { return }
                self.store = result
                for range in replacements.reversed() { self.shiftBookmarks(replacing: range, insertedCount: data.count, clamp: false) }
                self.bookmarks = self.bookmarks.map { bookmark in
                    var bookmark = bookmark; bookmark.offset = min(self.count, bookmark.offset)
                    bookmark.length = min(bookmark.length, max(0, self.count - bookmark.offset)); return bookmark
                }
                self.version = UUID(); self.undoManager.beginUndoGrouping()
                self.undoManager.registerUndo(withTarget: self) { $0.restore(before, name: "Replace All") }
                self.undoManager.setActionName("Replace All"); self.undoManager.endUndoGrouping()
                self.select(min(before.selection.lowerBound, self.count)..<min(before.selection.lowerBound, self.count))
                self.invalidateResults(); self.persistBookmarks(); self.onTitleChange?(); self.status = "Replaced \(replacements.count.formatted()) matches"
            }
        } catch { showError(error) }
    }

    func analyze(selectionOnly: Bool = false) {
        let snapshot = store, range = selectionOnly ? selection : 0..<count
        workspaceTab = .analysis
        showInspector = true; inspectorTab = 1
        runWork("Analyzing \(range.count.formatted()) bytes…", operation: { try ByteAnalysis.analyze(snapshot, range: range) }) { [weak self] report in
            self?.analysis = report; self?.analysisRange = range; self?.status = "Analysis complete"
        }
    }
    func activateWorkspace(_ tab: WorkspaceTab) {
        workspaceTab = tab
        if tab == .structure, structure == nil, !isBusy { parseStructure() }
        if tab == .analysis, analysis == nil, !isBusy { analyze() }
    }
    func parseStructure(selectionOnly: Bool = false) {
        let snapshot = store, range = selectionOnly ? selection : 0..<count, format = parserFormat
        workspaceTab = .structure
        runWork("Decoding file structure…", operation: { try BinaryStructure.parse(snapshot, range: range, format: format) }) { [weak self] report in
            self?.structure = report; self?.selectedStructureNode = report.nodes.first
            self?.status = report.warnings.isEmpty ? "Structure decoded" : "Structure decoded with \(report.warnings.count) notices"
        }
    }
    func selectStructureNode(_ node: BinaryNode) {
        selectedStructureNode = node
        if let range = node.range { select(range) }
    }
    func showBytes(_ range: Range<Int>) { workspaceTab = .bytes; select(range) }
    func findDigram(_ first: Int, _ second: Int) {
        guard let range = analysisRange else { return }
        let snapshot = store, pattern = BytePattern(data:Data([UInt8(clamping:first),UInt8(clamping:second)]))
        runWork("Finding byte pair…",operation:{ try ByteSearch.find(in:snapshot,pattern:pattern,range:range,limit:1) }) { [weak self] result in
            if let range = result.ranges.first { self?.showBytes(range); self?.status = "Selected first matching byte pair" }
        }
    }
    func extractStrings() {
        workspaceTab = .bytes
        let snapshot = store, minimum = minimumStringLength
        sidebarTab = .strings; showSidebar = true
        runWork("Extracting ASCII strings…", operation: { try ByteAnalysis.strings(in: snapshot, minimumLength: minimum) }) { [weak self] result in
            self?.foundStrings = result.strings; self?.stringsTruncated = result.truncated; self?.stringsHaveRun = true
            self?.status = "Found \(result.strings.count.formatted())\(result.truncated ? "+" : "") strings"
        }
    }
    func compare(with url: URL) {
        workspaceTab = .bytes
        let snapshot = store
        sidebarTab = .differences; showSidebar = true
        runWork("Comparing files…", operation: {
            let other = try ByteStore.open(url)
            return (try ByteAnalysis.compare(snapshot, other), other)
        }) { [weak self] result in
            self?.differences = result.0; self?.comparison = result.1; self?.comparisonName = url.lastPathComponent
            self?.status = "\(result.0.differingBytes.formatted()) differing bytes"
        }
    }
    func nextDifference(backwards: Bool = false) {
        guard let ranges = differences?.ranges, !ranges.isEmpty else { return }
        let range = backwards ? ranges.last(where: { $0.lowerBound < caret }) ?? ranges.last! : ranges.first(where: { $0.lowerBound > caret }) ?? ranges.first!
        showBytes(range)
    }
    func clearComparison() { differences = nil; comparison = nil; comparisonName = "" }

    func addBookmark(name: String? = nil) {
        let bookmark = Bookmark(id: UUID(), offset: caret, length: max(1, selection.count), name: name ?? "Offset 0x\(String(caret, radix: 16).uppercased())")
        bookmarks.append(bookmark); bookmarks.sort { $0.offset < $1.offset }; persistBookmarks()
        sidebarTab = .bookmarks; showSidebar = true
    }
    func removeBookmark(_ bookmark: Bookmark) { bookmarks.removeAll { $0.id == bookmark.id }; persistBookmarks() }
    func renameBookmark(_ bookmark: Bookmark, to name: String) {
        guard let i = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        bookmarks[i].name = name; persistBookmarks()
    }
    private func shiftBookmarks(replacing range: Range<Int>, insertedCount: Int, clamp: Bool = true) {
        let delta = insertedCount - range.count
        bookmarks = bookmarks.map { item in
            var item = item
            if item.offset >= range.upperBound { item.offset = max(0, item.offset + delta) }
            else if item.offset >= range.lowerBound { item.offset = range.lowerBound }
            if clamp { item.offset = min(count, item.offset); item.length = min(item.length, max(0, count - item.offset)) }
            return item
        }
    }
    private var bookmarkKey: String? { fileURL.map { "bookmarks:\($0.standardizedFileURL.path)" } }
    func persistBookmarks() { if let key = bookmarkKey, let data = try? JSONEncoder().encode(bookmarks) { UserDefaults.standard.set(data, forKey: key) } }
    private func loadBookmarks() {
        bookmarks = bookmarkKey.flatMap { UserDefaults.standard.data(forKey: $0) }.flatMap { try? JSONDecoder().decode([Bookmark].self, from: $0) } ?? []
        bookmarks = bookmarks.filter { $0.offset >= 0 && $0.offset <= count && $0.length >= 0 }
    }

    func save(to destination: URL? = nil, completion: (() -> Void)? = nil) {
        guard !isBusy else { return }
        pendingNibble = nil
        guard let url = destination ?? fileURL else { chooseSaveURL(completion: completion); return }
        let snapshot = store, expectedStamp = url == fileURL ? stamp : nil
        runWork("Saving…", cancellable: false, operation: {
            if let expectedStamp {
                guard let current = try? FileStamp(url: url), current == expectedStamp else {
                    throw HexaError.message("The file changed on disk. Use Save As to keep your edits in another file, or Revert to reload the disk version.")
                }
            }
            try snapshot.write(to: url, expectedStamp: expectedStamp)
            return try FileStamp(url: url)
        }) { [weak self] stamp in
            guard let self else { return }
            self.fileURL = url; self.stamp = stamp; self.displayName = url.lastPathComponent; self.isSample = false
            self.savedVersion = self.version; self.persistBookmarks(); self.status = "Saved \(self.count.formatted()) bytes"
            NSDocumentController.shared.noteNewRecentDocumentURL(url); self.onTitleChange?(); completion?()
        }
    }
    func chooseSaveURL(completion: (() -> Void)? = nil) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = displayName; panel.canCreateDirectories = true
        present(panel) { [weak self] response in if response == .OK, let url = panel.url { self?.save(to: url, completion: completion) } }
    }
    func exportSelection() {
        guard !selection.isEmpty, !isBusy else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Selection.bin"
        present(panel) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if url.standardizedFileURL == self.fileURL?.standardizedFileURL { self.errorMessage = "Export to a different file to keep the current document intact."; return }
            let snapshot = self.store, range = self.selection
            self.runWork("Exporting selection…", cancellable: false, operation: { try snapshot.write(to: url, range: range) }) { [weak self] _ in self?.status = "Selection exported" }
        }
    }
    func insertFile() {
        guard canEdit else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        present(panel) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            // Insertions currently use a single owned buffer; keep their allocation explicit and bounded.
            do {
                let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                guard size <= 64 * 1024 * 1024 else { throw HexaError.message("Insert File is limited to 64 MiB per operation.") }
                self.runWork("Reading inserted file…", operation: { try Data(contentsOf: url) }) { [weak self] data in self?.insert(data, name: "Insert File", useMode: false) }
            } catch { self.showError(error) }
        }
    }
    func chooseComparison() {
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.message = "Choose a file to compare at matching byte offsets."
        present(panel) { [weak self] response in if response == .OK, let url = panel.url { self?.compare(with: url) } }
    }
    func present(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(panel.runModal()) }
    }
    func cancelWork() { guard canCancelWork else { return }; workTask?.cancel(); workID = UUID(); workTask = nil; busyMessage = nil; status = "Cancelled" }
    private func runWork<T: Sendable>(_ label: String, cancellable: Bool = true, operation: @escaping @Sendable () throws -> T, completion: @escaping @MainActor (T) -> Void) {
        guard !isBusy else { NSSound.beep(); return }
        let id = UUID(); workID = id; busyMessage = label; canCancelWork = cancellable
        workTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let result = try operation()
                await MainActor.run {
                    guard self.workID == id else { return }
                    self.busyMessage = nil; self.workTask = nil; completion(result)
                }
            } catch {
                await MainActor.run {
                    guard self.workID == id else { return }
                    self.busyMessage = nil; self.workTask = nil
                    if error is CancellationError { self.status = "Cancelled" } else { self.showError(error) }
                }
            }
        }
    }
    private func invalidateResults() { clearSearchResults(); analysis = nil; analysisRange = nil; structure = nil; selectedStructureNode = nil; fileIdentity = FileMagic.identify(store); clearComparison(); foundStrings = []; stringsTruncated = false; stringsHaveRun = false }
    func showError(_ error: Error) { errorMessage = error.localizedDescription }
}
