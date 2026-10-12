import AudioToolbox
import AVFoundation
import CoreAudio

/// macOS seam for choosing dictation's microphone. Keeps the CoreAudio device
/// binding out of SpeechService so that service can move to Core for iOS.
///
/// Apple voice processing ("Reduce background noise") always follows the Mac's
/// default input, so a chosen microphone that isn't the default is bound
/// directly and recorded without it. Measured on macOS 27: binding before
/// enabling voice processing is reset to the default device; binding after it
/// fails to initialize (-10875).
enum DictationInputDevice {
    static let preferenceKey = "omniflow.dictation.microphoneUID"

    struct Plan: Sendable {
        /// Device to bind, or nil to use the system default.
        let deviceID: AudioDeviceID?
        let uid: String
        let name: String
        /// Voice processing is possible only on the system default input.
        let allowsVoiceProcessing: Bool
        let note: String?
    }

    /// The saved choice, empty for "System default".
    static var selectedUID: String {
        get { UserDefaults.standard.string(forKey: preferenceKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }

    /// Cheap enough for push-to-talk: a cached id is reused while the device is
    /// alive; the device list is only rescanned on a cache miss.
    static func plan(uid: String = selectedUID) -> Plan {
        let defaultID = VoiceMicrophone.defaultInputID()
        guard !uid.isEmpty else {
            return Plan(deviceID: nil, uid: "", name: VoiceMicrophone.health().name, allowsVoiceProcessing: true, note: nil)
        }
        guard let device = cache.device(for: uid) else {
            return Plan(deviceID: nil, uid: "", name: VoiceMicrophone.health().name, allowsVoiceProcessing: true,
                        note: "Your chosen microphone isn't connected, so the system default is used.")
        }
        let name = VoiceMicrophone.health(uid: uid).name
        if device == defaultID {
            return Plan(deviceID: nil, uid: uid, name: name, allowsVoiceProcessing: true, note: nil)
        }
        return Plan(deviceID: device, uid: uid, name: name, allowsVoiceProcessing: false,
                    note: "Background noise reduction is off for \(name) because it isn't the Mac's default input.")
    }

    /// Points the engine's input at `device`. Call before reading formats or installing taps.
    static func bind(_ input: AVAudioInputNode, to device: AudioDeviceID) -> Bool {
        input.withAudioUnit { unit in
            guard let unit else { return false }
            var id = device
            return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                        &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
        }
    }

    private static let cache = DeviceCache()

    private final class DeviceCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (uid: String, id: AudioDeviceID)?

        func device(for uid: String) -> AudioDeviceID? {
            if let cached = lock.withLock({ entry }), cached.uid == uid, Self.isAlive(cached.id) { return cached.id }
            guard let found = VoiceMicrophone.available().first(where: { $0.id == uid })?.deviceID else { return nil }
            lock.withLock { entry = (uid, found) }
            return found
        }

        private static func isAlive(_ device: AudioDeviceID) -> Bool {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var alive: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr && alive != 0
        }
    }
}
