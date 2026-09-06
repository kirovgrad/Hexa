import AppKit
import SwiftUI
import HexaCore

@main struct HexaMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--verify-bundle") {
            do {
                guard let sample = Bundle.main.url(forResource: "Welcome", withExtension: "bin"),
                      Bundle.main.url(forResource: "UserGuide", withExtension: "html") != nil,
                      let icon = Bundle.main.url(forResource: "Hexa", withExtension: "icns"), NSImage(contentsOf: icon) != nil else {
                    throw HexaError.message("The app bundle is missing a resource. Rebuild using Scripts/build-app.sh.")
                }
                let report = try ByteAnalysis.analyze(ByteStore.open(sample))
                print("Hexa bundle verified · \(report.count) sample bytes · icon and offline guide present")
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!
    private var controllers: [EditorWindowController] = []
    private var pendingURLs: [URL] = []
    private var launched = false
    var current: EditorModel? { (NSApp.keyWindow?.windowController as? EditorWindowController)?.model ?? controllers.last?.model }
    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus(); EditorSettings.shared.applyAppearance(); launched = true
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
        let urls = pendingURLs + arguments
        if urls.isEmpty { newWindow(sample: true) } else { urls.forEach(open) }
        NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ sender: NSApplication, open urls: [URL]) { if launched { urls.forEach(open) } else { pendingURLs += urls } }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { newWindow() }; return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = controllers.filter { $0.window?.isVisible == true }
        if active.contains(where: { $0.model.isBusy && !$0.model.canCancelWork }) {
            let alert = NSAlert(); alert.messageText = "A file is being saved"; alert.informativeText = "Wait for the save to finish before quitting."; alert.runModal(); return .terminateCancel
        }
        guard active.contains(where: { $0.model.isDirty }) else { active.forEach { $0.model.cancelWork() }; return .terminateNow }
        // Close in order using the same Save / Cancel / Don't Save flow as a document window.
        closeForTermination(active, index: 0)
        return .terminateLater
    }
    private func closeForTermination(_ windows: [EditorWindowController], index: Int) {
        guard index < windows.count else { NSApp.reply(toApplicationShouldTerminate: true); return }
        windows[index].confirmClose { [weak self] allowed in
            if allowed { self?.closeForTermination(windows, index: index + 1) } else { NSApp.reply(toApplicationShouldTerminate: false) }
        }
    }
    @discardableResult func newWindow(sample: Bool = false) -> EditorWindowController {
        let controller = EditorWindowController(model: EditorModel(sample: sample)); controllers.append(controller)
        controller.didClose = { [weak self, weak controller] in self?.controllers.removeAll { $0 === controller } }
        controller.showWindow(nil); return controller
    }
    func open(_ url: URL) {
        if let existing = controllers.first(where: { $0.model.fileURL?.standardizedFileURL == url.standardizedFileURL }) { existing.showWindow(nil); return }
        if let sample = controllers.first(where: { $0.model.isSample && !$0.model.isDirty && !$0.model.isBusy }) { sample.model.load(url); sample.showWindow(nil) }
        else { newWindow().model.load(url) }
    }
    @objc func newDocument(_ sender: Any?) { newWindow() }
    @objc func openPanel(_ sender: Any? = nil) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.begin { [weak self] response in if response == .OK { panel.urls.forEach { self?.open($0) } } }
    }
    @objc func openRecent(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { open(url) } }
    @objc func clearRecents(_ sender: Any?) { NSDocumentController.shared.clearRecentDocuments(sender) }
    @objc func showSettings(_ sender: Any?) { if current == nil { newWindow() }; current?.sheet = .preferences }
    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Hexa", .applicationVersion: "1.1", .version: "2", .credits: NSAttributedString(string: "A closer look at every byte.\nA native, local-first hexadecimal editor for macOS.")])
    }
    @objc func showHelp(_ sender: Any?) {
        if let url = Bundle.main.url(forResource: "UserGuide", withExtension: "html") { NSWorkspace.shared.open(url) }
        else {
            let alert = NSAlert(); alert.messageText = "Hexa Quick Start"; alert.informativeText = "⌘O Open  ·  ⌘S Save  ·  ⌘Z Undo\n⌘F Find  ·  ⌘G Next Match  ·  ⇧⌘G Previous Match\n⌘L Go to Offset  ·  ⇧⌘L Select Range\n⌘B Bookmark  ·  Tab Switch Hex / Text\n\nClick a byte and type two hex digits. Use Shift + arrows or drag to select. Choose Insert or Overwrite in the toolbar.\n\nSee README.md and docs/USER_GUIDE.md in the project for complete instructions."; alert.runModal()
        }
    }
    private func installMenus() {
        let main = NSMenu(); NSApp.mainMenu = main
        func menu(_ title: String) -> NSMenu { let item = NSMenuItem(); item.title = title; let submenu = NSMenu(title: title); item.submenu = submenu; main.addItem(item); return submenu }
        func add(_ menu: NSMenu, _ title: String, _ selector: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil, tag: Int = 0) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.keyEquivalentModifierMask = modifiers; item.target = target; item.tag = tag; menu.addItem(item)
        }
        let app = menu("Hexa")
        add(app, "About Hexa", #selector(showAbout), target: self); app.addItem(.separator())
        add(app, "Settings…", #selector(showSettings), ",", target: self); app.addItem(.separator())
        let services = NSMenu(); let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: ""); servicesItem.submenu = services; app.addItem(servicesItem); NSApp.servicesMenu = services
        app.addItem(.separator()); add(app, "Hide Hexa", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]); add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator()); add(app, "Quit Hexa", #selector(NSApplication.terminate(_:)), "q")
        let file = menu("File")
        add(file, "New", #selector(newDocument), "n", target: self); add(file, "Open…", #selector(openPanel), "o", target: self)
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: ""); let recent = NSMenu(title: "Open Recent"); recent.delegate = self; recentItem.submenu = recent; file.addItem(recentItem)
        file.addItem(.separator()); add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        add(file, "Save", #selector(EditorWindowController.saveDocument), "s")
        add(file, "Save As…", #selector(EditorWindowController.saveAs), "s", [.command, .shift])
        add(file, "Revert to Saved…", #selector(EditorWindowController.revertDocument)); file.addItem(.separator())
        add(file, "Insert File…", #selector(EditorWindowController.insertFile)); add(file, "Export Selection…", #selector(EditorWindowController.exportSelection), "e", [.command, .shift])
        let edit = menu("Edit")
        add(edit, "Undo", #selector(EditorWindowController.undoEdit), "z"); add(edit, "Redo", #selector(EditorWindowController.redoEdit), "z", [.command, .shift]); edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x"); add(edit, "Copy", #selector(NSText.copy(_:)), "c"); add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Paste as Text", #selector(EditorWindowController.pasteText), "v", [.command, .shift]); add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        let copyItem = NSMenuItem(title: "Copy As", action: nil, keyEquivalent: ""); let copy = NSMenu(title: "Copy As"); copyItem.submenu = copy; edit.addItem(copyItem)
        for (i, title) in ["Hex Bytes", "Text", "Hex Dump", "Swift Array", "Base64"].enumerated() { add(copy, title, #selector(EditorWindowController.copyAs(_:)), tag: i) }
        edit.addItem(.separator()); add(edit, "Edit Bytes…", #selector(EditorWindowController.editBytes), "e", [.command])
        add(edit, "Write Numeric Value…", #selector(EditorWindowController.writeNumber)); add(edit, "Fill / Insert Pattern…", #selector(EditorWindowController.fill)); add(edit, "Transform Selection…", #selector(EditorWindowController.transform))
        let find = menu("Find")
        add(find, "Find and Replace…", #selector(EditorWindowController.find), "f")
        add(find, "Find Next", #selector(EditorWindowController.findNext), "g"); add(find, "Find Previous", #selector(EditorWindowController.findPrevious), "g", [.command, .shift])
        find.addItem(.separator()); add(find, "Go to Offset…", #selector(EditorWindowController.goTo), "l"); add(find, "Select Range…", #selector(EditorWindowController.selectRange), "l", [.command, .shift])
        let view = menu("View")
        add(view, "Bytes", #selector(EditorWindowController.showBytes), "1")
        add(view, "Structure", #selector(EditorWindowController.showStructure), "2")
        add(view, "Analysis", #selector(EditorWindowController.showAnalysis), "3"); view.addItem(.separator())
        add(view, "Toggle Sidebar", #selector(EditorWindowController.toggleSidebar), "s", [.command, .option]); add(view, "Toggle Inspector", #selector(EditorWindowController.toggleInspector), "i", [.command, .option])
        view.addItem(.separator()); add(view, "Zoom In", #selector(EditorWindowController.zoomIn), "+"); add(view, "Zoom Out", #selector(EditorWindowController.zoomOut), "-"); add(view, "Actual Size", #selector(EditorWindowController.actualSize), "0")
        let tools = menu("Tools")
        add(tools, "Decode File Structure", #selector(EditorWindowController.decodeStructure))
        add(tools, "Decode Selection", #selector(EditorWindowController.decodeSelection)); tools.addItem(.separator())
        add(tools, "Add Bookmark", #selector(EditorWindowController.addBookmark), "b"); tools.addItem(.separator())
        add(tools, "Compare with File…", #selector(EditorWindowController.compare)); add(tools, "Next Difference", #selector(EditorWindowController.nextDifference), "]", [.command, .option]); add(tools, "Previous Difference", #selector(EditorWindowController.previousDifference), "[", [.command, .option])
        tools.addItem(.separator()); add(tools, "Analyze File", #selector(EditorWindowController.analyze)); add(tools, "Analyze Selection", #selector(EditorWindowController.analyzeSelection)); add(tools, "Extract ASCII Strings", #selector(EditorWindowController.strings))
        let window = menu("Window"); NSApp.windowsMenu = window
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"); add(window, "Zoom", #selector(NSWindow.performZoom(_:))); add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        let help = menu("Help"); NSApp.helpMenu = help; add(help, "Hexa Help", #selector(showHelp), "?", target: self)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: ""); item.target = self; item.representedObject = url; item.toolTip = url.path; menu.addItem(item)
        }
        if menu.items.isEmpty { let item = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: ""); menu.addItem(item) }
        menu.addItem(.separator()); let item = NSMenuItem(title: "Clear Menu", action: #selector(clearRecents), keyEquivalent: ""); item.target = self; menu.addItem(item)
    }
}

@MainActor final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let model: EditorModel
    var didClose: (() -> Void)?
    private var closingApproved = false
    init(model: EditorModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 830), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.minSize = NSSize(width: 1030, height: 560); window.center(); window.setFrameAutosaveName("HexaWorkspace")
        window.tabbingMode = .preferred; window.tabbingIdentifier = "HexaDocument"; window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true; window.delegate = self
        window.contentView = NSHostingView(rootView: WorkspaceView(model: model))
        model.window = window; model.onTitleChange = { [weak self] in self?.updateTitle() }; updateTitle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func updateTitle() { window?.title = "\(model.displayName) — Hexa"; window?.isDocumentEdited = model.isDirty; window?.representedURL = model.fileURL }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closingApproved { return true }
        confirmClose { [weak self] allowed in if allowed { self?.closingApproved = true; self?.window?.close() } }
        return false
    }
    func confirmClose(_ completion: @escaping (Bool) -> Void) {
        guard let window else { completion(true); return }
        if model.isBusy, !model.canCancelWork {
            let alert = NSAlert(); alert.messageText = "A file operation is finishing"; alert.informativeText = "Wait for it to finish before closing this document."; alert.beginSheetModal(for: window) { _ in completion(false) }; return
        }
        guard model.isDirty else { model.cancelWork(); completion(true); return }
        let alert = NSAlert(); alert.messageText = "Save changes to “\(model.displayName)”?"; alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Don’t Save")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { completion(false); return }
            switch response {
            case .alertFirstButtonReturn:
                self.model.cancelWork()
                // Save-panel cancellation and errors must also complete the deferred quit request.
                self.saveBeforeClosing(completion)
            case .alertThirdButtonReturn: self.model.cancelWork(); completion(true)
            default: completion(false)
            }
        }
    }
    private func saveBeforeClosing(_ completion: @escaping (Bool) -> Void) {
        if model.fileURL == nil {
            let panel = NSSavePanel(); panel.nameFieldStringValue = model.displayName
            model.present(panel) { [weak self] response in
                guard response == .OK, let url = panel.url, let self else { completion(false); return }
                self.awaitSave(to: url, completion)
            }
        } else { awaitSave(to: nil, completion) }
    }
    private func awaitSave(to url: URL?, _ completion: @escaping (Bool) -> Void) {
        model.save(to: url)
        Task { @MainActor [weak self] in
            while self?.model.isBusy == true { try? await Task.sleep(for: .milliseconds(50)) }
            completion(self?.model.isDirty == false)
        }
    }
    func windowWillClose(_ notification: Notification) { model.cancelWork(); model.undoManager.removeAllActions(); didClose?() }
    @objc func saveDocument() { model.save() }
    @objc func saveAs() { model.chooseSaveURL() }
    @objc func revertDocument() {
        guard let url = model.fileURL, let window else { return }
        let alert = NSAlert(); alert.messageText = "Revert to the saved file?"; alert.informativeText = "This discards all unsaved changes and the undo history."; alert.addButton(withTitle: "Revert"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in if response == .alertFirstButtonReturn { self?.model.load(url) } }
    }
    @objc func undoEdit() { model.undo() }
    @objc func redoEdit() { model.redo() }
    @objc func pasteText() { model.paste(asText: true) }
    @objc func copyAs(_ sender: NSMenuItem) { model.copy(format: ["hex", "text", "dump", "swift", "base64"][sender.tag]) }
    @objc func insertFile() { model.insertFile() }
    @objc func exportSelection() { model.exportSelection() }
    @objc func find() { model.workspaceTab = .bytes; model.showFind = true }
    @objc func findNext() { model.nextMatch() }
    @objc func findPrevious() { model.nextMatch(backwards: true) }
    @objc func goTo() { model.workspaceTab = .bytes; model.sheet = .goTo }
    @objc func selectRange() { model.workspaceTab = .bytes; model.sheet = .selectRange }
    @objc func editBytes() { model.sheet = .editBytes }
    @objc func fill() { model.sheet = .fill }
    @objc func transform() { model.sheet = .transform }
    @objc func writeNumber() { model.sheet = .numeric }
    @objc func addBookmark() { model.addBookmark() }
    @objc func compare() { model.chooseComparison() }
    @objc func nextDifference() { model.nextDifference() }
    @objc func previousDifference() { model.nextDifference(backwards: true) }
    @objc func analyze() { model.analyze() }
    @objc func analyzeSelection() { model.analyze(selectionOnly: true) }
    @objc func showBytes() { model.activateWorkspace(.bytes) }
    @objc func showStructure() { model.activateWorkspace(.structure) }
    @objc func showAnalysis() { model.activateWorkspace(.analysis) }
    @objc func decodeStructure() { model.parseStructure() }
    @objc func decodeSelection() { model.parseStructure(selectionOnly: true) }
    @objc func strings() { model.extractStrings() }
    @objc func toggleSidebar() { model.showSidebar = model.workspaceTab != .bytes || !model.showSidebar; model.workspaceTab = .bytes }
    @objc func toggleInspector() { model.showInspector = model.workspaceTab != .bytes || !model.showInspector; model.workspaceTab = .bytes }
    @objc func zoomIn() { EditorSettings.shared.fontSize = min(20, EditorSettings.shared.fontSize + 1) }
    @objc func zoomOut() { EditorSettings.shared.fontSize = max(10, EditorSettings.shared.fontSize - 1) }
    @objc func actualSize() { EditorSettings.shared.fontSize = 12 }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undoEdit): menuItem.title = model.undoManager.undoMenuItemTitle; return model.undoManager.canUndo && model.canEdit
        case #selector(redoEdit): menuItem.title = model.undoManager.redoMenuItemTitle; return model.undoManager.canRedo && model.canEdit
        case #selector(saveDocument), #selector(saveAs), #selector(compare), #selector(analyze), #selector(strings), #selector(decodeStructure): return !model.isBusy
        case #selector(decodeSelection): return !model.isBusy && !model.selection.isEmpty
        case #selector(revertDocument): return model.fileURL != nil && !model.isBusy
        case #selector(editBytes), #selector(fill), #selector(writeNumber), #selector(insertFile), #selector(pasteText): return model.canEdit
        case #selector(transform): return model.canEdit && !model.selection.isEmpty
        case #selector(exportSelection), #selector(analyzeSelection), #selector(copyAs(_:)): return !model.selection.isEmpty && !model.isBusy
        case #selector(findNext), #selector(findPrevious): return !model.searchResults.isEmpty
        case #selector(nextDifference), #selector(previousDifference): return !(model.differences?.ranges.isEmpty ?? true)
        default: return true
        }
    }
}
