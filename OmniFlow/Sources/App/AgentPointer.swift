import AppKit
import CryptoKit
import Darwin

struct AgentPointerAppearance: Equatable, Sendable {
    static let scaleRange = 0.75...3.0
    let scale: Double
    let colorHex: String

    init(scale: Double = 1, colorHex: String = "FFFFFF") {
        self.scale = scale.isFinite ? min(Self.scaleRange.upperBound, max(Self.scaleRange.lowerBound, scale)) : 1
        let hex = colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        self.colorHex = hex.count == 6 && hex.allSatisfy(\.isHexDigit) ? hex.uppercased() : "FFFFFF"
    }

    var color: CGColor {
        let value = UInt32(colorHex, radix: 16) ?? 0xFFFFFF
        return CGColor(red: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

/// Registers our artwork as the system arrow. WindowServer owns motion, visibility and
/// compositing: no overlay window, event-driven cursor setting, or hide/show calls.
@MainActor
final class AgentPointer {
    static let size = CGSize(width: 24, height: 25)
    static let hotSpot = CGPoint(x: 4, y: 4)
    // macOS 26+ uses the S variant in some apps. Both must carry identical artwork.
    static let cursorNames = ["com.apple.coregraphics.Arrow", "com.apple.coregraphics.ArrowS"]
    static var recoveryURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("NotchBuddy/Cursor/originals.plist")
    }

    @MainActor protocol System {
        var colorOverride: Bool { get }
        func read(_ name: String) -> CursorArtwork?
        func register(_ artwork: CursorArtwork, named name: String) -> Bool
    }

    private let system: (any System)?
    private let recoveryFile: URL?
    private var originals: [String: CursorArtwork] = [:]
    private var installed: CursorArtwork?
    private var ownedFingerprints = Set<String>()
    private var appearance = AgentPointerAppearance()
    private var active = false
    private(set) var failure: String?

    init(system: (any System)? = WindowServerCursor(), recoveryFile: URL? = AgentPointer.recoveryURL) {
        self.system = system
        self.recoveryFile = recoveryFile
    }

    @discardableResult
    func setAppearance(_ appearance: AgentPointerAppearance) -> Bool {
        guard appearance != self.appearance else { return failure == nil }
        self.appearance = appearance
        return !active || apply()
    }

    func start() -> Bool {
        guard !active else { return failure == nil }
        guard let system else { failure = "System cursor replacement is unavailable on this macOS version"; return false }
        // Restore an interrupted session before taking a fresh baseline. This also preserves
        // a user's existing theme if OmniFlow previously quit unexpectedly.
        guard recover() else { return false }
        guard !system.colorOverride else {
            failure = "Reset pointer colors in macOS Accessibility → Display to use the OmniFlow arrow"
            return false
        }
        for name in Self.cursorNames {
            guard let artwork = system.read(name) else {
                originals.removeAll()
                failure = "Could not read the macOS arrow; your current cursor is unchanged"
                return false
            }
            originals[name] = artwork
        }
        active = true
        return apply()
    }

    /// Called on workspace transitions and a slow health check, never on pointer motion.
    @discardableResult
    func refresh() -> Bool {
        guard active else { return start() }
        guard let system, let installed else { return false }
        if system.colorOverride {
            _ = stop()
            failure = "Reset pointer colors in macOS Accessibility → Display to use the OmniFlow arrow"
            return false
        }
        if failure == nil,
           Self.cursorNames.allSatisfy({ system.read($0)?.fingerprint == installed.fingerprint }) { return true }
        return apply()
    }

    @discardableResult
    func stop() -> Bool {
        active = false
        guard !originals.isEmpty else { return recover() }
        guard let system else { return false }
        var restored = true
        for (name, original) in originals {
            // Do not overwrite a different theme applied since ours.
            if let current = system.read(name), !ownedFingerprints.contains(current.fingerprint) { continue }
            if !system.register(original, named: name) { restored = false }
        }
        guard restored else { failure = "Could not restore the macOS arrow; turn the cursor off again to retry"; return false }
        originals.removeAll()
        installed = nil
        ownedFingerprints.removeAll()
        failure = nil
        return removeRecovery()
    }

    /// Also invoked at launch when the preference is off, to clean up after a crash.
    @discardableResult
    func recover() -> Bool {
        guard let recoveryFile, FileManager.default.fileExists(atPath: recoveryFile.path) else { return true }
        guard let system else { return false }
        do {
            let backup = try PropertyListDecoder().decode(CursorRecovery.self, from: Data(contentsOf: recoveryFile))
            for (name, record) in backup.originals where Self.cursorNames.contains(name) {
                guard let current = system.read(name) else { throw CursorRecovery.Error.unavailable }
                guard backup.ownedFingerprints.contains(current.fingerprint) else { continue }
                guard let artwork = record.artwork, system.register(artwork, named: name) else { throw CursorRecovery.Error.unavailable }
            }
            failure = nil
            return removeRecovery()
        } catch {
            failure = "Could not restore the saved macOS cursor"
            return false
        }
    }

    private func apply() -> Bool {
        guard let system, let next = AgentPointerDrawing.artwork(appearance: appearance) else {
            failure = "Could not create the OmniFlow cursor"
            return false
        }
        do {
            // Write before changing global state; retain both fingerprints during an update
            // so a crash halfway through registering two variants is recoverable.
            if let recoveryFile {
                let backup = try CursorRecovery(originals: originals, ownedFingerprints: Array(ownedFingerprints.union([next.fingerprint])))
                let folder = recoveryFile.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try PropertyListEncoder().encode(backup).write(to: recoveryFile, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryFile.path)
            }
        } catch {
            failure = "Could not save your current cursor for restoration"
            return false
        }
        ownedFingerprints.insert(next.fingerprint)
        let previous = installed
        var verified = false
        // macOS can rebuild the system arrow cache on the first read after a reset.
        // Let that initial read finish, then register again if necessary. Never retry
        // indefinitely or set a cursor during mouse movement.
        for _ in 0..<2 {
            var registered = true
            for name in Self.cursorNames {
                if !system.register(next, named: name) { registered = false; break }
            }
            guard registered else { break }
            if Self.cursorNames.allSatisfy({ system.read($0)?.fingerprint == next.fingerprint }) { verified = true; break }
        }
        guard verified else {
            var rolledBack = true
            for target in Self.cursorNames {
                if let original = previous ?? originals[target], !system.register(original, named: target) { rolledBack = false }
            }
            if previous == nil && rolledBack {
                active = false
                originals.removeAll()
                ownedFingerprints.removeAll()
                _ = removeRecovery()
            }
            failure = "macOS could not apply the OmniFlow cursor"
            return false
        }
        installed = next
        failure = nil
        return true
    }

    private func removeRecovery() -> Bool {
        guard let recoveryFile, FileManager.default.fileExists(atPath: recoveryFile.path) else { return true }
        do { try FileManager.default.removeItem(at: recoveryFile); return true }
        catch { failure = "Could not clear the saved cursor recovery file"; return false }
    }
}

/// Optional runtime interfaces to system frameworks already loaded by AppKit. These are
/// the modern macOS CGS ABI (size/hotspot precede frame count). No third-party engine.
@MainActor
final class WindowServerCursor: AgentPointer.System {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Read = @convention(c) (Int32, UnsafePointer<CChar>, UnsafeMutablePointer<CGSize>, UnsafeMutablePointer<CGPoint>, UnsafeMutablePointer<UInt>, UnsafeMutablePointer<CGFloat>, UnsafeMutablePointer<Unmanaged<CFArray>?>) -> Int32
    private typealias Register = @convention(c) (Int32, UnsafePointer<CChar>, Bool, Bool, CGSize, CGPoint, UInt, CGFloat, CFArray, UnsafeMutablePointer<Int32>) -> Int32
    private let connection: Int32
    private let copyImages: Read
    private let registerImages: Register

    init?() {
        #if APPSTORE
        return nil
        #else
        let symbols = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connection = dlsym(symbols, "CGSMainConnectionID"),
              let read = dlsym(symbols, "CGSCopyRegisteredCursorImages"),
              let register = dlsym(symbols, "CGSRegisterCursorWithImages") else { return nil }
        self.connection = unsafeBitCast(connection, to: Connection.self)()
        copyImages = unsafeBitCast(read, to: Read.self)
        registerImages = unsafeBitCast(register, to: Register.self)
        #endif
    }

    var colorOverride: Bool {
        // This domain is protected against app writes. Read it through the public API;
        // if customized, the user resets colors once in System Settings. Never pretend
        // a process-local preference cache changed the setting for other apps.
        let domain = "com.apple.universalaccess" as CFString
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue("cursorIsCustomized" as CFString, domain) as? Bool) ?? false
    }

    func read(_ name: String) -> CursorArtwork? {
        var size = CGSize.zero, hotSpot = CGPoint.zero, frames: UInt = 0, duration: CGFloat = 0
        var array: Unmanaged<CFArray>?
        let result = name.withCString { copyImages(connection, $0, &size, &hotSpot, &frames, &duration, &array) }
        let images = array?.takeRetainedValue() as? [CGImage]
        guard result == 0, let images, !images.isEmpty, size.width > 0, size.height > 0 else { return nil }
        return CursorArtwork(size: size, hotSpot: hotSpot, frames: frames, duration: duration, images: images)
    }

    func register(_ artwork: CursorArtwork, named name: String) -> Bool {
        var seed: Int32 = 0
        return name.withCString {
            registerImages(connection, $0, true, true, artwork.size, artwork.hotSpot,
                           artwork.frames, artwork.duration, artwork.images as CFArray, &seed) == 0
        }
    }
}

struct CursorArtwork {
    let size: CGSize
    let hotSpot: CGPoint
    let frames: UInt
    let duration: CGFloat
    let images: [CGImage]

    // Normalize pixel format; WindowServer can return a different byte order/color space.
    var fingerprint: String {
        var hash = SHA256()
        hash.update(data: Data("\(size)|\(hotSpot)|\(frames)|\(duration)|\(images.count)".utf8))
        for image in images {
            hash.update(data: Data("\(image.width)x\(image.height)".utf8))
            guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let bytes = context.data else { return "" }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            hash.update(data: Data(bytes: bytes, count: image.width * image.height * 4))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct CursorRecovery: Codable {
    enum Error: Swift.Error { case unavailable }
    struct Record: Codable {
        let size: CGSize
        let hotSpot: CGPoint
        let frames: UInt
        let duration: CGFloat
        let images: [Data]

        init(_ artwork: CursorArtwork) throws {
            size = artwork.size; hotSpot = artwork.hotSpot; frames = artwork.frames; duration = artwork.duration
            images = try artwork.images.map {
                guard let data = NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) else { throw Error.unavailable }
                return data
            }
        }
        var artwork: CursorArtwork? {
            let decoded = images.compactMap { NSBitmapImageRep(data: $0)?.cgImage }
            guard decoded.count == images.count, !decoded.isEmpty else { return nil }
            return CursorArtwork(size: size, hotSpot: hotSpot, frames: frames, duration: duration, images: decoded)
        }
    }
    let originals: [String: Record]
    let ownedFingerprints: [String]

    init(originals: [String: CursorArtwork], ownedFingerprints: [String]) throws {
        self.originals = try originals.mapValues { try Record($0) }
        self.ownedFingerprints = ownedFingerprints
    }
}

/// Original OmniFlow arrow, with a white fill and a customizable outline.
@MainActor
enum AgentPointerDrawing {
    static func artwork(appearance: AgentPointerAppearance) -> CursorArtwork? {
        let size = CGSize(width: AgentPointer.size.width * appearance.scale, height: AgentPointer.size.height * appearance.scale)
        var images: [CGImage] = []
        // Retina plus Accessibility's larger pointer scales, all drawn from the same path.
        for density in [1.0, 2.0, 5.0, 10.0] {
            let width = Int((size.width * density).rounded(.up)), height = Int((size.height * density).rounded(.up))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: CGFloat(width) / size.width, y: -CGFloat(height) / size.height)
            draw(context, appearance: appearance)
            guard let image = context.makeImage() else { return nil }
            images.append(image)
        }
        return CursorArtwork(size: size, hotSpot: CGPoint(x: AgentPointer.hotSpot.x * appearance.scale, y: AgentPointer.hotSpot.y * appearance.scale), frames: 1, duration: 0, images: images)
    }

    static func draw(_ context: CGContext, appearance: AgentPointerAppearance = .init()) {
        context.saveGState()
        context.scaleBy(x: appearance.scale, y: appearance.scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setShadow(offset: .zero, blur: 1.4, color: CGColor(gray: 0, alpha: 0.65))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(appearance.color)
        context.setLineWidth(1.2)
        context.beginPath()
        context.move(to: AgentPointer.hotSpot)
        context.addLine(to: CGPoint(x: 19, y: 10))
        context.addQuadCurve(to: CGPoint(x: 18.5, y: 11.5), control: CGPoint(x: 20, y: 11))
        context.addLine(to: CGPoint(x: 12.5, y: 13.5))
        context.addLine(to: CGPoint(x: 10, y: 19.5))
        context.addQuadCurve(to: CGPoint(x: 8.5, y: 19.5), control: CGPoint(x: 9.2, y: 21))
        context.closePath()
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }
}
