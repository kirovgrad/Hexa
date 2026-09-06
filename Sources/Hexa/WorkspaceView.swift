import SwiftUI
import AppKit
import HexaCore

struct WorkspaceView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var settings = EditorSettings.shared
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            workspaceNavigation
            Divider()
            if model.workspaceTab == .structure {
                StructureExplorerView(model: model)
            } else if model.workspaceTab == .analysis {
                AnalysisDashboardView(model: model)
            } else { HStack(spacing: 0) {
                if model.showSidebar { SidebarView(model: model).frame(width: 210); Divider() }
                VStack(spacing: 0) {
                    if model.showFind { FindBar(model: model); Divider() }
                    if model.isSample { sampleBanner; Divider() }
                    HexGrid(model: model, settings: settings)
                    gridFooter
                }.frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
                if model.showInspector { Divider(); InspectorView(model: model).frame(width: 282) }
            } }
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.blue)
        .sheet(item: $model.sheet) { sheet in EditorSheetView(model: model, kind: sheet) }
        .alert("Hexa", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private var workspaceNavigation: some View {
        HStack(spacing: 5) {
            ForEach(WorkspaceTab.allCases,id: \.self) { tab in
                Button { model.activateWorkspace(tab) } label: {
                    Label(tab.rawValue,systemImage:tab == .bytes ? "number" : tab == .structure ? "list.bullet.indent" : "chart.xyaxis.line")
                        .font(.system(size:11,weight:.medium)).padding(.horizontal,13).padding(.vertical,7)
                        .foregroundStyle(model.workspaceTab == tab ? Color.accentColor : .secondary)
                        .background(model.workspaceTab == tab ? Color.accentColor.opacity(0.1):.clear,in:RoundedRectangle(cornerRadius:6))
                }.buttonStyle(.plain)
            }
            Spacer()
            Text(model.fileIdentity.name).font(.system(size:10,weight:.medium)).lineLimit(1)
            Text(model.fileIdentity.mime).font(.system(size:9,design:.monospaced)).foregroundStyle(.tertiary).lineLimit(1)
        }.padding(.horizontal,16).frame(height:43).background(.bar)
    }
    private var toolbar: some View {
        HStack(spacing: 14) {
            Button { model.showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }.help("Toggle sidebar · ⌘⌥S").disabled(model.workspaceTab != .bytes)
            Divider().frame(height: 18)
            Image(systemName: "doc").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) { Text(model.displayName).font(.system(size: 12, weight: .semibold)); if model.isDirty { Circle().fill(.orange).frame(width: 5, height: 5) } }
                Text(model.isSample ? "SAMPLE DOCUMENT" : model.fileURL?.deletingLastPathComponent().path ?? "NEW DOCUMENT")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button { model.isReadOnly.toggle() } label: { Image(systemName: model.isReadOnly ? "lock.fill" : "lock.open") }.help(model.isReadOnly ? "Enable editing" : "Lock editing")
            Picker("", selection: $model.editMode) { ForEach(EditMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().accessibilityLabel("Edit mode").frame(width: 160).disabled(model.isReadOnly)
            Divider().frame(height: 18)
            Button { model.showFind = model.workspaceTab != .bytes || !model.showFind; model.workspaceTab = .bytes } label: { Image(systemName: "magnifyingglass") }.help("Find and replace · ⌘F")
            Menu {
                Button("Go to Offset…") { model.workspaceTab = .bytes; model.sheet = .goTo }
                Button("Select Range…") { model.workspaceTab = .bytes; model.sheet = .selectRange }
                Button("Decode File Structure") { model.parseStructure() }
                Button("Decode Selection") { model.parseStructure(selectionOnly:true) }.disabled(model.selection.isEmpty)
                Divider()
                Button("Edit Bytes…") { model.sheet = .editBytes }.disabled(!model.canEdit)
                Button("Fill / Insert Pattern…") { model.sheet = .fill }.disabled(!model.canEdit)
                Button("Transform Selection…") { model.sheet = .transform }.disabled(!model.canEdit || model.selection.isEmpty)
                Divider()
                Button("Compare with File…") { model.chooseComparison() }
                Button("Analyze File") { model.analyze() }
                Button("Extract Strings") { model.extractStrings() }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22).accessibilityLabel("Tools").help("Tools")
            Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("Toggle inspector · ⌘⌥I").disabled(model.workspaceTab != .bytes)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 15))
        .padding(.horizontal, 18).frame(height: 57)
        .background(.bar)
    }
    private var sampleBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.blue)
            Text("A closer look at every byte.").font(.system(size: 11, weight: .medium))
            Text("Explore this sample, or open your own file.").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Open File…") { AppDelegate.shared.openPanel() }.font(.system(size: 11, weight: .medium))
        }.padding(.horizontal, 19).padding(.vertical, 12).background(Color.blue.opacity(0.045))
    }
    private var gridFooter: some View {
        HStack(spacing: 13) {
            Label("Edited since open", systemImage: "minus").foregroundStyle(.orange)
            if model.structure != nil && model.showStructureColors { Label("Structure",systemImage:"square.fill").foregroundStyle(.blue) }
            if !model.searchResults.isEmpty { Label("Match", systemImage: "square.fill").foregroundStyle(.yellow) }
            if model.differences != nil { Label("Difference", systemImage: "square.fill").foregroundStyle(.pink) }
            Spacer(minLength: 0)
            Text("TAB").font(.system(size: 8, weight: .semibold, design: .monospaced)).padding(.horizontal, 4).padding(.vertical, 2).background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            Text("switch hex / text").foregroundStyle(.tertiary)
        }.font(.system(size: 9)).padding(.horizontal, 18).frame(height: 29).background(Color(nsColor: .textBackgroundColor))
    }
    private var statusBar: some View {
        HStack(spacing: 14) {
            if let busy = model.busyMessage {
                ProgressView().controlSize(.mini)
                Text(busy).lineLimit(1)
                if model.canCancelWork { Button("Cancel") { model.cancelWork() }.buttonStyle(.link) }
            } else {
                Circle().fill(model.isReadOnly ? Color.orange : Color.green).frame(width: 5, height: 5)
                Text(model.isReadOnly ? "Read only" : model.pendingNibble != nil ? "Enter second hex digit" : model.status).lineLimit(1)
            }
            Spacer()
            Text("\(model.count.formatted()) bytes")
            Divider().frame(height: 11)
            Button { model.sheet = .goTo } label: { Text("0x\(String(model.caret, radix: 16).uppercased())").monospaced() }.buttonStyle(.plain).help("Go to offset")
            Text("\(model.selection.count.formatted()) selected").foregroundStyle(.secondary)
            Divider().frame(height: 11)
            Menu(model.encoding.rawValue) { ForEach(TextEncoding.allCases) { encoding in Button(encoding.rawValue) { model.encoding = encoding } } }.menuStyle(.borderlessButton).fixedSize()
            Menu(settings.columns == 0 ? "Auto columns" : "\(settings.columns) bytes / row") {
                ForEach([0, 8, 16, 32], id: \.self) { value in Button(value == 0 ? "Automatic" : "\(value) bytes per row") { settings.columns = value } }
            }.menuStyle(.borderlessButton).fixedSize()
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 31).background(.bar)
    }
}

struct FindBar: View {
    @ObservedObject var model: EditorModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.searchHex ? "Hex pattern · DE AD ?? B?" : "Find text", text: $model.query).textFieldStyle(.roundedBorder).focused($focused).onSubmit { model.find() }
                Picker("Search format", selection: $model.searchHex) { Text("Hex").tag(true); Text("Text").tag(false) }.labelsHidden().frame(width: 81)
                Button("Find") { model.find() }.disabled(model.isBusy || model.query.isEmpty)
                Button { model.nextMatch(backwards: true) } label: { Image(systemName: "chevron.up") }.help("Previous match · ⇧⌘G").disabled(model.searchResults.isEmpty)
                Button { model.nextMatch() } label: { Image(systemName: "chevron.down") }.help("Next match · ⌘G").disabled(model.searchResults.isEmpty)
                Button { model.showFind = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Close search")
            }
            HStack(spacing: 9) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary)
                TextField(model.searchHex ? "Replacement hex bytes" : "Replacement text", text: $model.replacement).textFieldStyle(.roundedBorder)
                Button("Replace") { model.replaceMatch() }.disabled(!model.canEdit || model.searchResults.isEmpty)
                Button("Replace All") { model.replaceAll() }.disabled(!model.canEdit || model.searchResults.isEmpty || model.searchTruncated)
                Toggle("Selection", isOn: $model.searchSelectionOnly).toggleStyle(.checkbox).font(.system(size: 11))
            }
        }.controlSize(.small).padding(13).background(.bar)
        .onAppear { focused = true }
        .onChange(of: model.query) { _, _ in model.clearSearchResults() }
        .onChange(of: model.searchHex) { _, _ in model.clearSearchResults() }
        .onChange(of: model.encoding) { _, _ in model.clearSearchResults() }
        .onChange(of: model.searchSelectionOnly) { _, _ in model.clearSearchResults() }
    }
}

struct SidebarView: View {
    @ObservedObject var model: EditorModel
    @State private var renamed: Bookmark?
    @State private var newName = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 23, weight: .light)).foregroundStyle(.blue.gradient)
                VStack(alignment: .leading, spacing: 3) { Text("Hexa").font(.system(size: 18, weight: .semibold)); Text("BINARY WORKSPACE").font(.system(size: 8, weight: .semibold)).tracking(1.1).foregroundStyle(.tertiary) }
                Spacer()
            }.padding(.horizontal, 19).padding(.vertical, 24)
            HStack(spacing: 0) {
                ForEach(SidebarTab.allCases, id: \.self) { tab in
                    Button { model.sidebarTab = tab } label: {
                        Image(systemName: icon(tab)).font(.system(size: 13)).frame(maxWidth: .infinity).frame(height: 29)
                            .foregroundStyle(model.sidebarTab == tab ? Color.accentColor : .secondary)
                            .background(model.sidebarTab == tab ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).help(tab.rawValue)
                }
            }.padding(.horizontal, 12).padding(.bottom, 21)
            HStack {
                Text(model.sidebarTab.rawValue.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                if model.sidebarTab == .bookmarks { Button { model.addBookmark() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("Add bookmark · ⌘B") }
            }.padding(.horizontal, 19).padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    switch model.sidebarTab {
                    case .bookmarks: bookmarkList
                    case .search: searchList
                    case .differences: differenceList
                    case .strings: stringList
                    }
                }.padding(.horizontal, 10).padding(.bottom, 16)
            }
            Divider().padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 9) {
                Label("DOCUMENT", systemImage: "doc.text").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                HStack { Text("Size"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(model.count), countStyle: .file)).foregroundStyle(.primary) }
                HStack { Text("Editing"); Spacer(); Text(model.isReadOnly ? "Locked" : model.editMode.rawValue).foregroundStyle(.primary) }
                HStack { Text("Changes"); Spacer(); Text(model.isDirty ? "Unsaved" : "Saved").foregroundStyle(model.isDirty ? .orange : .secondary) }
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(19)
        }.background(.regularMaterial)
        .alert("Rename Bookmark", isPresented: Binding(get: { renamed != nil }, set: { if !$0 { renamed = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renamed = nil }
            Button("Rename") { if let renamed { model.renameBookmark(renamed, to: newName) }; renamed = nil }
        }
    }
    private func icon(_ tab: SidebarTab) -> String { switch tab { case .bookmarks: return "bookmark"; case .search: return "magnifyingglass"; case .differences: return "square.split.2x1"; case .strings: return "text.alignleft" } }
    @ViewBuilder private var bookmarkList: some View {
        if model.bookmarks.isEmpty { empty("Mark a place", "Save an offset or selection with ⌘B.", icon: "bookmark") }
        ForEach(model.bookmarks) { bookmark in
            Button { model.select(bookmark.offset..<(bookmark.offset + min(bookmark.length, model.count - bookmark.offset))) } label: {
                sidebarRow(bookmark.name, detail: "0x\(String(bookmark.offset, radix: 16).uppercased()) · \(bookmark.length) bytes", icon: "bookmark.fill", tint: .orange, active: model.caret == bookmark.offset)
            }.buttonStyle(.plain).contextMenu {
                Button("Rename…") { newName = bookmark.name; renamed = bookmark }
                Button("Remove", role: .destructive) { model.removeBookmark(bookmark) }
            }
        }
    }
    @ViewBuilder private var searchList: some View {
        if !model.searchHasRun { empty("Find a sequence", "Search hex, wildcard patterns, or encoded text with ⌘F.", icon: "magnifyingglass"); Button("Find in File") { model.showFind = true }.padding(10) }
        else if model.searchResults.isEmpty { empty("No matches", "Try another pattern or encoding.", icon: "magnifyingglass") }
        else {
            Text("\(model.searchResults.count.formatted())\(model.searchTruncated ? "+" : "") matches").font(.system(size: 10)).foregroundStyle(.secondary).padding(9)
            ForEach(Array(model.searchResults.prefix(2_000).enumerated()), id: \.offset) { index, range in
                Button { model.selectMatch(index) } label: { sidebarRow("0x\(String(range.lowerBound, radix: 16).uppercased())", detail: ByteFormatting.hex(model.store.data(in: range.lowerBound..<(range.lowerBound + min(7, range.count)))), icon: "scope", tint: .blue, active: model.searchIndex == index) }.buttonStyle(.plain)
            }
            if model.searchResults.count > 2_000 { Text("First 2,000 shown. Use ⌘G to navigate all results.").font(.caption).foregroundStyle(.secondary).padding(9) }
        }
    }
    @ViewBuilder private var differenceList: some View {
        if let report = model.differences {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.comparisonName).font(.system(size: 11, weight: .medium)).lineLimit(2)
                Text("\(report.differingBytes.formatted()) bytes differ · offset aligned").font(.system(size: 10)).foregroundStyle(.secondary)
                HStack { Button { model.nextDifference(backwards: true) } label: { Image(systemName: "chevron.up") }; Button { model.nextDifference() } label: { Image(systemName: "chevron.down") }; Spacer(); Button("Clear") { model.clearComparison() } }.controlSize(.small)
            }.padding(9)
            if report.differingBytes == 0 { empty("Identical files", "Every byte matches.", icon: "checkmark.circle") }
            ForEach(Array(report.ranges.prefix(2_000).enumerated()), id: \.offset) { _, range in
                Button { model.select(range) } label: {
                    sidebarRow("0x\(String(range.lowerBound, radix: 16).uppercased())", detail: "\(range.count.formatted()) differing bytes", icon: "square.split.2x1", tint: .pink, active: model.caret == min(model.count, range.lowerBound))
                }.buttonStyle(.plain)
            }
            if report.ranges.count > 2_000 || report.truncated { Text("List shows the first 2,000 ranges. Navigation covers up to 100,000 ranges.").font(.caption).foregroundStyle(.secondary).padding(9) }
        } else { empty("Spot the difference", "Compare two files at matching byte offsets.", icon: "square.split.2x1"); Button("Choose File…") { model.chooseComparison() }.padding(10) }
    }
    @ViewBuilder private var stringList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper("Minimum: \(model.minimumStringLength)", value: $model.minimumStringLength, in: 2...64).font(.system(size: 10))
            Button("Extract ASCII Strings") { model.extractStrings() }.disabled(model.isBusy).controlSize(.small)
            if model.stringsHaveRun { Text("\(model.foundStrings.count.formatted())\(model.stringsTruncated ? "+" : "") strings").font(.system(size: 10)).foregroundStyle(.secondary) }
        }.padding(9)
        if model.foundStrings.isEmpty { empty(model.stringsHaveRun ? "No strings found" : "Find readable content", "Printable ASCII sequences, with their offsets.", icon: "text.alignleft") }
        ForEach(model.foundStrings) { string in
            Button { model.select(string.offset..<(string.offset + string.length)) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(string.text).font(.system(size: 11, design: .monospaced)).lineLimit(2).foregroundStyle(.primary)
                    Text("0x\(String(string.offset, radix: 16).uppercased()) · \(string.length) bytes").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(9).background(model.caret == string.offset ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).contextMenu { Button("Copy String") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(string.text, forType: .string) } }
        }
    }
    private func sidebarRow(_ title: String, detail: String, icon: String, tint: Color, active: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint).frame(width: 15).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary).lineLimit(1); Text(detail).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1) }
            Spacer(minLength: 0)
        }.padding(.horizontal, 9).padding(.vertical, 10).background(active ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
    private func empty(_ title: String, _ description: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) { Image(systemName: icon).font(.system(size: 25, weight: .ultraLight)).foregroundStyle(.tertiary).padding(.top, 15); Text(title).font(.system(size: 12, weight: .medium)); Text(description).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }.padding(10)
    }
}
