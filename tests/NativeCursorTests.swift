import AppKit

@main
enum NativeCursorTests {
    @MainActor final class FakeSystem: AgentPointer.System {
        var colorOverride = false
        var writes = 0
        var failNames: [String] = []
        let baseline = AgentPointerDrawing.artwork(appearance: .init(colorHex: "112233"))!
        var values: [String: CursorArtwork] = [:]
        init() { for name in AgentPointer.cursorNames { values[name] = baseline } }
        func read(_ name: String) -> CursorArtwork? { values[name] }
        func register(_ artwork: CursorArtwork, named name: String) -> Bool {
            writes += 1
            if failNames.first == name { failNames.removeFirst(); return false }
            values[name] = artwork
            return true
        }
    }

    @MainActor static func main() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent("notchlee-cursor-tests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recovery = folder.appendingPathComponent("recovery.plist")
        let system = FakeSystem()
        let pointer = AgentPointer(system: system, recoveryFile: recovery)
        precondition(pointer.start() && pointer.start())
        precondition(system.writes == 2 && !system.colorOverride)
        precondition(FileManager.default.fileExists(atPath: recovery.path))
        for _ in 0..<20 { precondition(pointer.refresh()) }
        precondition(system.writes == 2, "Movement and health checks must not re-register a healthy cursor")
        precondition(pointer.setAppearance(.init(scale: 2, colorHex: "FF8800")))
        for name in AgentPointer.cursorNames {
            let artwork = system.values[name]!
            precondition(artwork.size == CGSize(width: 48, height: 50))
            precondition(artwork.hotSpot == CGPoint(x: 8, y: 8))
            precondition(artwork.images.map(\.width) == [48, 96, 240, 480])
            let inside = NSBitmapImageRep(cgImage: artwork.images[0]).colorAt(x: 20, y: 20)!.usingColorSpace(.sRGB)!
            precondition(inside.alphaComponent > 0.99 && inside.redComponent > 0.99 && inside.greenComponent > 0.99 && inside.blueComponent > 0.99, "The arrow must have an opaque white fill")
        }
        // macOS can reset registrations at a session or display transition.
        system.values[AgentPointer.cursorNames[1]] = system.baseline
        precondition(pointer.refresh())
        precondition(system.values.values.allSatisfy { $0.fingerprint != system.baseline.fingerprint })
        precondition(pointer.stop() && pointer.stop())
        precondition(system.values.values.allSatisfy { $0.fingerprint == system.baseline.fingerprint })
        precondition(!system.colorOverride && !FileManager.default.fileExists(atPath: recovery.path))

        system.failNames = [AgentPointer.cursorNames[1]]
        precondition(!pointer.start())
        precondition(system.values.values.allSatisfy { $0.fingerprint == system.baseline.fingerprint })
        precondition(!system.colorOverride && !FileManager.default.fileExists(atPath: recovery.path))
        precondition(pointer.stop())

        // A failed rollback must keep recovery data, including the newly written fingerprint.
        system.failNames = [AgentPointer.cursorNames[1], AgentPointer.cursorNames[0]]
        precondition(!pointer.start())
        precondition(FileManager.default.fileExists(atPath: recovery.path))
        precondition(pointer.stop())
        precondition(system.values.values.allSatisfy { $0.fingerprint == system.baseline.fingerprint })

        precondition(pointer.start())
        let recovered = AgentPointer(system: system, recoveryFile: recovery)
        precondition(recovered.recover(), "An interrupted session must restore exact cursor pixels")
        precondition(system.values.values.allSatisfy { $0.fingerprint == system.baseline.fingerprint })
        precondition(!system.colorOverride)
        precondition(pointer.stop())

        precondition(pointer.start())
        let thirdParty = AgentPointerDrawing.artwork(appearance: .init(colorHex: "0000FF"))!
        system.values[AgentPointer.cursorNames[0]] = thirdParty
        precondition(pointer.stop())
        precondition(system.values[AgentPointer.cursorNames[0]]?.fingerprint == thirdParty.fingerprint)

        let denied = FakeSystem()
        denied.colorOverride = true
        let unavailable = AgentPointer(system: denied, recoveryFile: nil)
        precondition(!unavailable.start() && denied.writes == 0 && denied.colorOverride)
        precondition(unavailable.stop())
        let preferencesChanged = FakeSystem()
        let conditional = AgentPointer(system: preferencesChanged, recoveryFile: nil)
        precondition(conditional.start())
        preferencesChanged.colorOverride = true
        precondition(!conditional.refresh())
        precondition(preferencesChanged.values.values.allSatisfy { $0.fingerprint == preferencesChanged.baseline.fingerprint })
        precondition(preferencesChanged.colorOverride, "Never fight the user's macOS pointer preferences")
        preferencesChanged.colorOverride = false
        precondition(conditional.refresh(), "Resume after the user resets pointer colors")
        precondition(conditional.stop())
        print("Native cursor lifecycle, white fill, scaling, rollback and crash recovery: passed")

        if CommandLine.arguments.contains("--system") {
            try await checkSystem(recovery: folder.appendingPathComponent("system.plist"))
        }
    }

    struct CheckFailure: Error { let message: String }
    @MainActor static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message: message) }
    }

    @MainActor static func checkSystem(recovery: URL) async throws {
        guard let system = WindowServerCursor() else { throw CheckFailure(message: "Cursor APIs unavailable") }
        let before = AgentPointer.cursorNames.map { system.read($0)!.fingerprint }
        let textBefore = system.read("com.apple.coregraphics.IBeam")!.fingerprint
        let overrideBefore = system.colorOverride
        let pointer = AgentPointer(system: system, recoveryFile: recovery)
        defer { _ = pointer.stop() }
        try require(pointer.start(), pointer.failure ?? "Registration failed")
        try require(!system.colorOverride, "macOS color override is still active")
        try require(try externalColorOverride() == false, "Other apps still see the macOS color override")
        print("System arrow registered; native cursor active")
        fflush(stdout)
        let seconds = CommandLine.arguments.contains("--hold") ? 30 : 2
        for _ in 0..<seconds {
            try await Task.sleep(for: .seconds(1))
            try require(pointer.refresh(), pointer.failure ?? "Registration was reset")
        }
        for scale in [0.75, 1.25, 3.0] {
            try require(pointer.setAppearance(.init(scale: scale, colorHex: "FF8800")), pointer.failure ?? "Appearance update failed")
            let expected = AgentPointerDrawing.artwork(appearance: .init(scale: scale, colorHex: "FF8800"))!.fingerprint
            for name in AgentPointer.cursorNames { try require(system.read(name)?.fingerprint == expected, "Wrong registered pixels") }
        }
        try require(system.read("com.apple.coregraphics.IBeam")?.fingerprint == textBefore, "Text cursor changed")
        try require(pointer.stop(), pointer.failure ?? "Restore failed")
        try require(system.colorOverride == overrideBefore, "Original pointer color preference not restored")
        try require(try externalColorOverride() == overrideBefore, "Other apps did not receive the restored color preference")
        try require(AgentPointer.cursorNames.map { system.read($0)!.fingerprint } == before, "Original arrow pixels not restored")
        print("Real WindowServer registration, size/color changes and restoration: passed")
    }

    /// Catch a setter that only changes its own CFPreferences cache, which otherwise
    /// passes in-process checks while the old pointer keeps returning in other apps.
    static func externalColorOverride() throws -> Bool {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "com.apple.universalaccess", "cursorIsCustomized"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }
}
