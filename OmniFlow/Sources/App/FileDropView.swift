import AppKit
import SwiftUI

// MARK: - NSView drag destination
// Wired at the AppKit level in IslandWindowController (not via SwiftUI NSViewRepresentable)
// so it never interferes with SwiftUI hit-testing.

final class FileDropNSView: NSView {
    var onDragEntered: ((CGPoint) -> Void)?
    var onDragUpdated: ((CGPoint) -> Void)?
    var onDragExited:  (() -> Void)?
    var onFilesDropped: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    // AppKit also calls this from background Accessibility hit testing on macOS 26+.
    // It reads no view state; avoid a MainActor assertion in the Objective-C entry point.
    // Drag-drop uses NSDraggingDestination, so all ordinary hits pass through.
    nonisolated override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEntered?(sender.draggingLocation)
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragUpdated?(sender.draggingLocation)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragExited?() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }
}

// MARK: - File drop handler

enum FileDropHandler {
    @MainActor
    static func handle(urls: [URL], state: AppState) async {
        guard let url = urls.first else { return }
        let name = url.lastPathComponent

        // Readiness reflects an actual local copy, not a timed upload simulation.
        UploadSequenceEngine.shared.deactivate()
        state.droppedFile = DroppedFile(url: url, name: name)
        state.fileDragOver = false
        state.view = .uploading
        let inbox = HookServer.supportDir.appendingPathComponent("inbox")
        do {
            let copy = try await Task.detached(priority: .utility) {
                let folder = inbox.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent(name)
                do { try FileManager.default.copyItem(at: url, to: destination) }
                catch { try? FileManager.default.removeItem(at: folder); throw error }
                return destination
            }.value
            guard state.droppedFile?.url == url else { return }
            state.droppedFile = DroppedFile(url: copy, name: name)
            state.promptContext = .file(name: name, fileURL: copy)
            SoundEngine.shared.play("approve")
            if state.view == .uploading { state.view = .choose }
        } catch {
            guard state.droppedFile?.url == url else { return }
            state.droppedFile = nil
            state.promptContext = nil
            state.noteMessage = "Could not add \(name): \(error.localizedDescription)"
            if state.view == .uploading { state.view = .note }
        }
    }
}
