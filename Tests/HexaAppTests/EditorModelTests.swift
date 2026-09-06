import XCTest
import HexaCore
@testable import Hexa

final class EditorModelTests: XCTestCase {
    @MainActor func testTwoNibblesOneUndoAndNoOpAdvances() async throws {
        let model = EditorModel()
        model.typeHex("A")
        XCTAssertEqual(model.count, 0); XCTAssertFalse(model.isDirty)
        model.typeHex("B")
        XCTAssertEqual(model.store.byte(at: 0), 0xAB); XCTAssertTrue(model.isDirty)
        model.undo(); XCTAssertEqual(model.count, 0); XCTAssertFalse(model.isDirty)
        model.redo(); XCTAssertEqual(model.store.byte(at: 0), 0xAB)
        model.select(0..<1); model.typeHex("A"); model.typeHex("B")
        XCTAssertEqual(model.caret, 1)
        model.undo(); XCTAssertEqual(model.count, 0, "Identical typing must not create an edit")
    }
    @MainActor func testSelectionReplacementInsertAndOverwrite() async throws {
        let model = EditorModel()
        model.insert(Data([1, 2, 3, 4]), name: "Initial")
        model.select(1..<2); model.editMode = .insert
        model.insert(Data([8, 9]), name: "Insert")
        XCTAssertEqual(model.store.data(in: 0..<model.count), Data([1, 8, 9, 2, 3, 4]))
        model.select(1..<4); model.insert(Data([0]), name: "Replace")
        XCTAssertEqual(model.store.data(in: 0..<model.count), Data([1, 0, 3, 4]))
        model.editMode = .overwrite; model.select(3..<4); model.insert(Data([5, 6]), name: "Overwrite")
        XCTAssertEqual(model.store.data(in: 0..<model.count), Data([1, 0, 3, 5, 6]))
        model.undo(); XCTAssertEqual(model.store.data(in: 0..<model.count), Data([1, 0, 3, 4]))
    }
    @MainActor func testReadOnlyAndBookmarkShift() async throws {
        let model = EditorModel()
        model.insert(Data([1, 2, 3, 4]), name: "Initial"); model.select(2..<3); model.addBookmark(name: "Target")
        model.isReadOnly = true; model.delete()
        XCTAssertEqual(model.count, 4)
        model.isReadOnly = false; model.select(0..<1); model.editMode = .insert; model.insert(Data([8, 9]), name: "Insert")
        XCTAssertEqual(model.bookmarks.first?.offset, 4)
        model.undo(); XCTAssertEqual(model.bookmarks.first?.offset, 2)
    }
    @MainActor func testReplaceAllUsesDisjointMatchesAndUndo() async throws {
        let model = EditorModel(); model.insert(Data([0xAA, 0xAA, 0xAA]), name: "Initial")
        model.query = "AA AA"; model.replacement = "BB"; model.find(); try await wait(model)
        XCTAssertEqual(model.searchResults, [0..<2, 1..<3])
        model.replaceAll(); try await wait(model)
        XCTAssertEqual(model.store.data(in: 0..<model.count), Data([0xBB, 0xAA]))
        model.undo(); XCTAssertEqual(model.store.data(in: 0..<model.count), Data([0xAA, 0xAA, 0xAA]))
        XCTAssertTrue(model.searchResults.isEmpty)
    }
    @MainActor func testSaveUndoRedoAndReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Hexa-model-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url); UserDefaults.standard.removeObject(forKey: "bookmarks:\(url.standardizedFileURL.path)") }
        let model = EditorModel(); model.insert(Data([1, 2]), name: "Initial")
        model.save(to: url); try await wait(model)
        XCTAssertFalse(model.isDirty); XCTAssertNil(model.errorMessage)
        model.select(0..<1); model.insert(Data([3]), name: "Change")
        XCTAssertTrue(model.isDirty); model.undo(); XCTAssertFalse(model.isDirty)
        model.redo(); XCTAssertTrue(model.isDirty)
        model.save(); try await wait(model); XCTAssertFalse(model.isDirty)
        let reopened = EditorModel(); reopened.load(url); try await wait(reopened)
        XCTAssertEqual(reopened.store.data(in: 0..<reopened.count), Data([3, 2])); XCTAssertFalse(reopened.isDirty)
    }
    @MainActor func testBookmarksInShrinkingBatchReplacement() async throws {
        let model = EditorModel(); model.insert(Data("one two one".utf8), name: "Initial")
        model.select(10..<11); model.addBookmark(name: "Last word")
        model.searchHex = false; model.query = "one"; model.replacement = "1"
        model.find(); try await wait(model); model.replaceAll(); try await wait(model)
        XCTAssertEqual(model.bookmarks.first?.offset, 6)
        model.undo(); XCTAssertEqual(model.bookmarks.first?.offset, 10)
    }
    @MainActor func testCancelledSearchDoesNotPublishResults() async throws {
        let model = EditorModel(); model.insert(Data(repeating: 0xAA, count: 10000), name: "Initial")
        model.query = "AA"; model.find(); model.cancelWork()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(model.isBusy); XCTAssertTrue(model.searchResults.isEmpty)
    }
    @MainActor func testStructureAnalysisNavigationAndInvalidation() async throws {
        let model = EditorModel()
        model.insert(Data([0, 0, 0xAB, 0xCD, 0, 0xAB, 0xCD]), name: "Fixture")
        model.select(2..<7); model.parseStructure(selectionOnly: true); try await wait(model)
        XCTAssertEqual(model.workspaceTab, .structure)
        XCTAssertEqual(model.structure?.range, 2..<7)
        let field = try XCTUnwrap(model.structure?.allNodes.first { $0.kind == .field && $0.range == 2..<3 })
        model.selectStructureNode(field)
        XCTAssertEqual(model.selection, 2..<3); XCTAssertEqual(model.workspaceTab, .structure)
        model.showBytes(3..<7); model.analyze(selectionOnly: true); try await wait(model)
        XCTAssertEqual(model.analysisRange, 3..<7); XCTAssertEqual(model.workspaceTab, .analysis)
        model.findDigram(0xAB, 0xCD); try await wait(model)
        XCTAssertEqual(model.selection, 5..<7, "Pair navigation must remain inside the analyzed selection")
        XCTAssertEqual(model.workspaceTab, .bytes)
        model.insert(Data([0xFF]), name: "Edit")
        XCTAssertNil(model.analysis); XCTAssertNil(model.structure); XCTAssertNil(model.selectedStructureNode)
        model.undo(); XCTAssertNil(model.analysis); XCTAssertNil(model.structure)
    }
    @MainActor func testCommandsNavigateOutOfAnalysis() async throws {
        let model = EditorModel(); model.insert(Data("hello".utf8), name: "Fixture")
        let controller = EditorWindowController(model: model)
        model.workspaceTab = .analysis; controller.find()
        XCTAssertEqual(model.workspaceTab, .bytes); XCTAssertTrue(model.showFind)
        model.workspaceTab = .structure; controller.goTo()
        XCTAssertEqual(model.workspaceTab, .bytes); model.sheet = nil
        model.workspaceTab = .analysis; model.extractStrings(); try await wait(model)
        XCTAssertEqual(model.workspaceTab, .bytes); XCTAssertEqual(model.foundStrings.count, 1)
        controller.close()
    }
    @MainActor private func wait(_ model: EditorModel) async throws {
        let end = Date().addingTimeInterval(5)
        while model.isBusy, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isBusy, "Operation timed out"); XCTAssertNil(model.errorMessage)
    }
}
