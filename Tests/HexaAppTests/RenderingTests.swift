import XCTest
import AppKit
import SwiftUI
import HexaCore
@testable import Hexa

final class RenderingTests: XCTestCase {
    /// Optional offscreen rendering of our own views; does not operate other apps or capture the desktop.
    @MainActor func testWorkspaceRendering() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HEXA_RENDER_DIR"] else { throw XCTSkip("Set HEXA_RENDER_DIR to render preview artifacts.") }
        _ = NSApplication.shared
        let model = EditorModel(sample: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: WorkspaceView(model: model))
        window.contentView = hosting
        model.window = window
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("workspace", NSAppearance.Name.aqua), ("workspace-dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            model.select(0..<4)
            try await Task.sleep(for: .milliseconds(200))
            hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            XCTAssertGreaterThan(png.count, 10_000)
        }
        model.inspectorTab = 1; model.analyze()
        while model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("analysis-sample-dark.png"))
        model.showFind = true; model.query = "45"; model.find()
        while model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let searchBitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: searchBitmap)
        try XCTUnwrap(searchBitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("search-dark.png"))
    }
    @MainActor func testStructureAndDashboardRendering() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HEXA_RENDER_DIR"] else { throw XCTSkip("Set HEXA_RENDER_DIR to render preview artifacts.") }
        _ = NSApplication.shared
        var model = EditorModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: WorkspaceView(model: model)); window.contentView = hosting; model.window = window
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        func capture(_ name: String, appearance: NSAppearance.Name) async throws {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(400))
            hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            XCTAssertGreaterThan(png.count, 10_000)
        }
        func finishWork() async throws {
            let deadline = Date().addingTimeInterval(10)
            while model.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(model.isBusy); XCTAssertNil(model.errorMessage)
        }
        model.load(URL(fileURLWithPath: "/bin/ls")); try await finishWork()
        model.activateWorkspace(.structure)
        XCTAssertEqual(model.structure?.identity.format, .machO)
        try await capture("structure", appearance: .aqua)
        try await capture("structure-dark", appearance: .darkAqua)
        window.setContentSize(NSSize(width: 1030, height: 700))
        try await capture("structure-compact", appearance: .aqua)
        window.setContentSize(NSSize(width: 1400, height: 850))
        model.showBytes(0..<min(32, model.count))
        try await capture("structure-bytes-dark", appearance: .darkAqua)
        // Deterministic regions give the graphs clear patterns without using private user data.
        model = EditorModel(); model.window = window; hosting.rootView = WorkspaceView(model: model)
        var data = Data(repeating: 0, count: 16_384)
        data.append(Data(String(repeating: "A closer look at every byte.\n", count: 585).utf8))
        for _ in 0..<128 { data.append(Data(0...255)) }
        var state: UInt64 = 0x12345678
        for _ in 0..<32_768 { state = state &* 6364136223846793005 &+ 1; data.append(UInt8(truncatingIfNeeded: state >> 32)) }
        for signature in CryptographicConstants.signatures.prefix(6) { data.append(contentsOf: signature.bytes) }
        model.isReadOnly = false; model.edit(0..<model.count, data: data, name: "Visualization fixture")
        model.analyze(); try await finishWork()
        try await capture("analysis-dark", appearance: .darkAqua)
        window.setContentSize(NSSize(width: 1400, height: 1760))
        try await capture("analysis-full", appearance: .aqua)
        try await capture("analysis-full-dark", appearance: .darkAqua)
    }
}
