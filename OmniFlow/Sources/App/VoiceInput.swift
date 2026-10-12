@preconcurrency import AVFoundation
import CoreAudio
import Speech
import os

/// Stage boundaries of one voice turn. Only their timing is ever recorded:
/// never audio, words or device names.
enum VoiceMilestone: Sendable {
    case turnStarted, micStarted, analyzerReady, firstPartial, endOfSpeech, finalTranscript
    case modelFirstToken, replyDone, ttsFirstAudio
}

enum VoiceSignpost {
    static let signposter = OSSignposter(subsystem: "com.mengohlabs.NotchLee", category: "VoiceLatency")
}

enum OmniFlowMicrophonePermission: Equatable {
    case allowed, notRequested, denied, restricted, unknown

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .allowed
        case .notDetermined: self = .notRequested
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .unknown
        }
    }

    static var current: Self { .init(AVCaptureDevice.authorizationStatus(for: .audio)) }
    var label: String {
        switch self {
        case .allowed: "Allowed"
        case .notRequested: "Not requested"
        case .denied: "Not allowed"
        case .restricted: "Restricted by macOS"
        case .unknown: "Unavailable"
        }
    }
    var guidance: String {
        switch self {
        case .allowed: "Microphone permission is allowed. Sound still needs to reach the selected input."
        case .notRequested: "Allow microphone access to use dictation or talk to Omni."
        case .denied: "Microphone access is off. Enable OmniFlow in System Settings → Privacy & Security → Microphone."
        case .restricted: "macOS restricts microphone access. Check Screen Time or your device administrator's restrictions."
        case .unknown: "macOS could not report microphone permission. Check Privacy & Security → Microphone."
        }
    }
    var actionTitle: String { self == .notRequested ? "Allow microphone" : "Open microphone settings" }
}

/// A cancelled UI operation can still be releasing hardware on its capture
/// queue. Every microphone owner waits for those releases before opening input.
@MainActor
final class VoiceCaptureRelease {
    static let shared = VoiceCaptureRelease()
    private var pending: Task<Void, Never>?
    private var generation: UInt64 = 0

    func enqueue(_ release: @escaping @MainActor () async -> Void) {
        let previous = pending
        generation &+= 1
        pending = Task {
            await previous?.value
            await release()
        }
    }

    func wait() async {
        while let pending {
            let ticket = generation
            await pending.value
            if ticket == generation { return }
        }
    }
}

enum VoiceInputError: LocalizedError {
    case microphoneDenied, unsupportedLanguage, modelDownloadRequired, unavailableInput, selectedInputUnavailable, audioBacklog, inputChanged, stalledInput, hardwareMuted, processMuted

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "Allow OmniFlow in System Settings → Privacy & Security → Microphone, then try again."
        case .unsupportedLanguage: return "Speech recognition isn't available for your Mac's language. You can still type a question."
        case .modelDownloadRequired: return "Download Apple's speech support once to recognize your voice on this Mac."
        case .unavailableInput: return "No usable microphone was found. Check your Mac's sound input and try again."
        case .selectedInputUnavailable: return "The selected microphone is unavailable. Reconnect it or choose another microphone in OmniFlow Settings → Voice."
        case .audioBacklog: return "Speech recognition couldn't keep up. Try a shorter recording."
        case .inputChanged: return "The microphone connection changed. Try again."
        case .stalledInput: return "The microphone stopped delivering audio. Check the input device and try again."
        case .hardwareMuted: return "Your Mac's input device is muted. Unmute the microphone, then try again."
        case .processMuted: return "macOS has muted microphone audio for OmniFlow. Check the microphone controls for this app, then try again."
        }
    }
}

/// Stable device UIDs survive reconnects. Selecting an input affects this app only.
struct VoiceMicrophone: Identifiable, Equatable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID
    static let preferenceKey = "voiceMicrophoneUID"

    struct Health: Sendable {
        let name: String
        let hardwareMuted: Bool?
        let processMuted: Bool?
        var error: VoiceInputError? {
            if hardwareMuted == true { return .hardwareMuted }
            if processMuted == true { return .processMuted }
            return nil
        }
        var description: String { name + " · " + muteDescription }
        var muteDescription: String {
            "device mute \(hardwareMuted.map { $0 ? "on" : "off" } ?? "unreported") · app mute \(processMuted.map { $0 ? "on" : "off" } ?? "unreported")"
        }
    }

    /// Read-only, inside the capturing process: process mute queried from a
    /// helper would describe that helper, not OmniFlow. Never unmute implicitly.
    static func health(uid: String = "") -> Health {
        let device = uid.isEmpty ? defaultInputID() : available().first { $0.id == uid }?.deviceID
        guard let device else { return Health(name: "No input device", hardwareMuted: nil, processMuted: nil) }
        func flag(_ selector: AudioObjectPropertySelector, object: AudioObjectID) -> Bool? {
            for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeGlobal] {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
                guard AudioObjectHasProperty(object, &address) else { continue }
                var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr { return value != 0 }
            }
            return nil
        }
        let deviceMute = flag(kAudioDevicePropertyProcessMute, object: device)
        let inputMute = flag(kAudioHardwarePropertyProcessInputMute, object: AudioObjectID(kAudioObjectSystemObject))
        let processMute: Bool? = deviceMute == true || inputMute == true ? true
            : (deviceMute == false && inputMute == false ? false : nil)
        return Health(name: stringProperty(kAudioObjectPropertyName, device: device) ?? "System microphone",
                      hardwareMuted: flag(kAudioDevicePropertyMute, object: device), processMuted: processMute)
    }

    static func available() -> [VoiceMicrophone] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { device in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, device: device),
                  let name = stringProperty(kAudioObjectPropertyName, device: device) else { return nil }
            return VoiceMicrophone(id: uid, name: name, deviceID: device)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func captureDevice(for uid: String) throws -> AVCaptureDevice {
        let selectedUID = uid.isEmpty
            ? defaultInputID().flatMap { stringProperty(kAudioDevicePropertyDeviceUID, device: $0) }
            : uid
        guard let selectedUID, let device = AVCaptureDevice(uniqueID: selectedUID), device.hasMediaType(.audio) else {
            throw VoiceInputError.selectedInputUnavailable
        }
        return device
    }

    static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultInputID() -> AudioDeviceID? {
        var address = defaultInputAddress
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

@MainActor
protocol OmniFlowDictationRecording: AnyObject {
    func start(locale: Locale?, downloadIfNeeded: Bool,
        onStatus: @escaping @MainActor (String) -> Void,
        onTranscript: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void,
        onActivity: @escaping @MainActor (Double, String) -> Void,
        onFormat: @escaping @MainActor (String) -> Void) async throws
    func finish() async throws -> String
    func cancel()
}

/// One recording owns one analyzer. Cancellation cannot tear down a later recording.
@MainActor
final class VoiceInput: OmniFlowDictationRecording {
    private var capture: VoiceMicrophoneCapture?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    private var resultsTask: Task<Void, Error>?
    private var downloadProgress: Progress?
    private var transcript = VoiceTranscript()
    private var cancelled = false
    private var inputMonitor: Task<Void, Never>?
    private var defaultInputObserver: AudioObjectPropertyListenerBlock?
    private var lastAudioAt = Date()
    private var reportedPartial = false
    private var captureStartedAt: Date?
    private var transcriptFloor = 0.0
    var onMilestone: (@MainActor (VoiceMilestone) -> Void)?
    /// True once the microphone is delivering into this recording, possibly
    /// before the analyzer is ready; that audio is kept for transcription.
    var isCapturing: Bool { capture != nil && !cancelled }

    // Resolved per session: locale support and installed assets do not change
    // between recordings. An analyzer preparation failure clears the asset entry.
    private static var supportedLocales: [String: Locale] = [:]
    private static var installedAssets = Set<String>()

    func start(locale selectedLocale: Locale? = nil, downloadIfNeeded: Bool,
               onStatus: @escaping @MainActor (String) -> Void,
               onTranscript: @escaping @MainActor (String) -> Void,
               onFailure: @escaping @MainActor (Error) -> Void,
               onActivity: @escaping @MainActor (Double, String) -> Void = { _, _ in },
               onFormat: @escaping @MainActor (String) -> Void = { _ in }) async throws {
        await VoiceCaptureRelease.shared.wait()
        try checkCancellation()
        let locale = selectedLocale ?? Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
        let module: any SpeechModule
        let readResults: @MainActor () -> Task<Void, Error>
        let assetKey: String
        if SpeechTranscriber.isAvailable,
           let supported = await Self.cachedLocale(locale, kind: "speech", resolve: SpeechTranscriber.supportedLocale(equivalentTo:)) {
            assetKey = "speech|" + supported.identifier
            let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                                reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            module = transcriber
            readResults = { [weak self] in
                Task { @MainActor in
                    do {
                        for try await result in transcriber.results {
                            try Task.checkCancellation()
                            guard let self, !self.cancelled else { return }
                            guard result.range.start.seconds >= self.transcriptFloor else { continue }
                            self.transcript.update(text: String(result.text.characters),
                                                   start: result.range.start.seconds, end: result.range.end.seconds, isFinal: result.isFinal)
                            self.reportPartial()
                            onTranscript(self.transcript.text)
                        }
                    } catch { if !Task.isCancelled { onFailure(error) }; throw error }
                }
            }
        } else if let supported = await Self.cachedLocale(locale, kind: "dictation", resolve: DictationTranscriber.supportedLocale(equivalentTo:)) {
            assetKey = "dictation|" + supported.identifier
            let transcriber = Self.makeDictationTranscriber(locale: supported)
            module = transcriber
            readResults = { [weak self] in
                Task { @MainActor in
                    do {
                        for try await result in transcriber.results {
                            try Task.checkCancellation()
                            guard let self, !self.cancelled else { return }
                            guard result.range.start.seconds >= self.transcriptFloor else { continue }
                            self.transcript.update(text: String(result.text.characters),
                                                   start: result.range.start.seconds, end: result.range.end.seconds, isFinal: result.isFinal)
                            self.reportPartial()
                            onTranscript(self.transcript.text)
                        }
                    } catch { if !Task.isCancelled { onFailure(error) }; throw error }
                }
            }
        } else {
            throw VoiceInputError.unsupportedLanguage
        }
        try checkCancellation()

        // The inventory status can say "supported" even when shared system assets exist.
        // A nil installation request is Apple's authoritative "nothing to download" result.
        if !Self.installedAssets.contains(assetKey) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                guard downloadIfNeeded else { throw VoiceInputError.modelDownloadRequired }
                onStatus("Downloading speech support…")
                downloadProgress = request.progress
                try await request.downloadAndInstall()
                downloadProgress = nil
            }
            Self.installedAssets.insert(assetKey)
        }
        try checkCancellation()
        onStatus("Preparing microphone…")
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw VoiceInputError.microphoneDenied }
        default: throw VoiceInputError.microphoneDenied
        }
        try checkCancellation()

        let microphoneUID = UserDefaults.standard.string(forKey: VoiceMicrophone.preferenceKey) ?? ""
        if let error = VoiceMicrophone.health(uid: microphoneUID).error { throw error }
        let device = try VoiceMicrophone.captureDevice(for: microphoneUID)
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: device.activeFormat.formatDescription)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: sourceFormat)
        else { throw VoiceInputError.unavailableInput }
        // Open the microphone first. Audio buffers in the stream while the analyzer
        // prepares, so the first words of a push-to-talk request are not lost.
        let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(4096))
        self.continuation = continuation
        let microphoneName = device.localizedName
        let capture = VoiceMicrophoneCapture(device: device, destination: format, continuation: continuation, onLevel: { [weak self] level in
            Task { @MainActor in
                guard let self, !self.cancelled, self.capture != nil else { return }
                self.lastAudioAt = .now
                onActivity(level, microphoneName)
            }
        }, onFormat: { [weak self] description in
            Task { @MainActor in
                guard let self, !self.cancelled, self.capture != nil else { return }
                onFormat(description)
            }
        })
        try checkCancellation()
        self.capture = capture
        try await capture.start()
        try checkCancellation()
        lastAudioAt = .now
        captureStartedAt = .now
        onMilestone?(.micStarted)
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        do {
            try await Self.addWakeVocabulary(to: analyzer)
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            Self.installedAssets.remove(assetKey)
            throw error
        }
        try checkCancellation()
        resultsTask = readResults()
        try await analyzer.start(inputSequence: stream)
        try checkCancellation()
        onMilestone?(.analyzerReady)
        lastAudioAt = .now
        if (UserDefaults.standard.string(forKey: VoiceMicrophone.preferenceKey) ?? "").isEmpty {
            let observer: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.cancelled, self.capture != nil else { return }
                    onFailure(VoiceInputError.inputChanged)
                }
            }
            var address = VoiceMicrophone.defaultInputAddress
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, observer) == noErr {
                defaultInputObserver = observer
            }
        }
        inputMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, !cancelled, self.capture != nil else { return }
                if Date().timeIntervalSince(lastAudioAt) > 4 {
                    onFailure(VoiceInputError.stalledInput)
                    return
                }
            }
        }
    }

    func finish() async throws -> String {
        // Finalize first. The hardware release is queued and completes in the
        // background; the next recording waits for it before opening input.
        stopMicrophone()
        try checkCancellation()
        continuation?.finish()
        continuation = nil
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        try await resultsTask?.value
        try checkCancellation()
        analyzer = nil
        resultsTask = nil
        return transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cachedLocale(_ locale: Locale, kind: String,
                                     resolve: (Locale) async -> Locale?) async -> Locale? {
        let key = kind + "|" + locale.identifier
        if let cached = supportedLocales[key] { return cached }
        let supported = await resolve(locale)
        if let supported { supportedLocales[key] = supported }
        return supported
    }

    static func addWakeVocabulary(to analyzer: SpeechAnalyzer) async throws {
        let context = AnalysisContext()
        context.contextualStrings[.general] = WakePhrase.vocabulary
        try await analyzer.setContext(context)
    }

    static func makeDictationTranscriber(locale: Locale) -> DictationTranscriber {
        // Hands-free speech can be farther from the microphone and runs continuously.
        DictationTranscriber(locale: locale, contentHints: [.farField], transcriptionOptions: [.punctuation],
                             reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
    }

    /// Discard recognized text without stopping capture or the analyzer. Late
    /// results for audio before this point (approximated by capture wall time)
    /// are dropped so they cannot repopulate the transcript.
    func resetTranscript() {
        transcript = VoiceTranscript()
        transcriptFloor = captureStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    func cancel() {
        cancelled = true
        stopMicrophone()
        downloadProgress?.cancel()
        downloadProgress = nil
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
    }

    private func reportPartial() {
        guard !reportedPartial, !transcript.text.isEmpty else { return }
        reportedPartial = true
        onMilestone?(.firstPartial)
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    private func stopMicrophone() {
        inputMonitor?.cancel(); inputMonitor = nil
        if let defaultInputObserver {
            var address = VoiceMicrophone.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultInputObserver)
            self.defaultInputObserver = nil
        }
        if let capture {
            VoiceCaptureRelease.shared.enqueue { await capture.stop() }
        }
        capture = nil
    }
}

/// Capture only the chosen microphone. This avoids AVAudioEngine's implicit
/// input/output aggregate when Bluetooth input and USB output use different rates.
/// Session configuration, delegate delivery and conversion share one serial queue.
final class VoiceMicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "notchlee.microphone", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let device: AVCaptureDevice
    private let destination: AVAudioFormat
    private let continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
    private let onLevel: @Sendable (Double) -> Void
    private let onFormat: @Sendable (String) -> Void
    private var bridge: VoiceAudioBridge?
    private var bridgeInputFormat: AVAudioFormat?
    private var stopped = false
    private var formatDescription = ""
    private let firstBuffer: FirstBufferSignal?
    private let onSpectrum: (@Sendable ([Float], [Float]) -> Void)?
    private var spectrum: DictationSpectrumTap?
    private var checkedFrames: AVAudioFrameCount = 0
    private var sourcePeak: Float = -160
    private var sampleLevel = 0.0
    private var reportedSignal = false

    init(device: AVCaptureDevice, destination: AVAudioFormat,
         continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation,
         onLevel: @escaping @Sendable (Double) -> Void,
         onFormat: @escaping @Sendable (String) -> Void,
         onFirstBuffer: (@Sendable (Date) -> Void)? = nil,
         onSpectrum: (@Sendable ([Float], [Float]) -> Void)? = nil) {
        self.firstBuffer = onFirstBuffer.map(FirstBufferSignal.init)
        self.onSpectrum = onSpectrum
        self.device = device; self.destination = destination
        self.continuation = continuation; self.onLevel = onLevel
        self.onFormat = onFormat
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard !stopped else { throw CancellationError() }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    // Accept the device's native PCM. Forcing a partial 32-bit
                    // format here can fail when switching Bluetooth/USB routes.
                    output.audioSettings = nil
                    output.setSampleBufferDelegate(self, queue: queue)
                    session.beginConfiguration()
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        session.commitConfiguration()
                        throw VoiceInputError.unavailableInput
                    }
                    session.addInput(input); session.addOutput(output)
                    session.commitConfiguration()
                    session.startRunning()
                    guard session.isRunning else { throw VoiceInputError.unavailableInput }
                    result.resume()
                } catch { result.resume(throwing: error) }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { result in
            queue.async { [self] in
                stopped = true
                session.stopRunning()
                for output in session.outputs { (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil) }
                bridge = nil
                result.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !stopped, sampleBuffer.numSamples > 0 else { return }
        do {
            let buffer = try VoiceCapturePCM.copy(sampleBuffer)
            let format = buffer.format
            if bridge == nil || bridgeInputFormat?.isEqual(format) != true {
                bridge = try VoiceAudioBridge(source: format, destination: destination, continuation: continuation, onLevel: onLevel)
                bridgeInputFormat = format
                spectrum = onSpectrum.map { DictationSpectrumTap(sampleRate: format.sampleRate, deliver: $0) }
                checkedFrames = 0; sourcePeak = -160; sampleLevel = 0; reportedSignal = false
                formatDescription = "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, PCM \(format.streamDescription.pointee.mBitsPerChannel)-bit \(format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatFloat64 ? "float" : "integer") → \(Int(destination.sampleRate)) Hz"
                onFormat(formatDescription)
            }
            // Compare Apple's capture meter with our copied PCM, once per session.
            // Only numeric health information is retained; no audio or words.
            if !reportedSignal {
                checkedFrames += buffer.frameLength
                sourcePeak = max(sourcePeak, connection.audioChannels.map(\.peakHoldLevel).max() ?? -160)
                sampleLevel = max(sampleLevel, VoiceAudioBridge.level(of: buffer))
                if checkedFrames >= AVAudioFrameCount(format.sampleRate * 8) {
                    reportedSignal = true
                    let enabled = connection.isEnabled && connection.audioChannels.allSatisfy(\.isEnabled)
                    onFormat(formatDescription + "; channel \(enabled ? "enabled" : "disabled"), source peak \(Int(sourcePeak)) dB, sample level \(Int(sampleLevel * 100))%; " + VoiceMicrophone.health(uid: device.uniqueID).muteDescription)
                }
            }
            firstBuffer?.fire()
            bridge?.tap(buffer, AVAudioTime(sampleTime: 0, atRate: format.sampleRate))
            spectrum?.process(buffer)
        } catch { continuation.finish(throwing: error) }
    }
}

/// Validate capture metadata before crossing into AVFAudio. Route changes can
/// deliver unusable formats; the legacy Core Media initializer could return nil
/// despite importing into Swift as nonoptional, crashing PCM buffer allocation.
enum VoiceCapturePCM {
    static func copy(_ sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        let frames = sampleBuffer.numSamples
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              frames > 0, frames <= Int(Int32.max),
              let description = sampleBuffer.formatDescription,
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              asbd.pointee.mSampleRate.isFinite, asbd.pointee.mSampleRate > 0,
              asbd.pointee.mChannelsPerFrame > 0,
              asbd.pointee.mBytesPerFrame > 0,
              let format = AVAudioFormat(formatDescription: description),
              [.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32].contains(format.commonFormat),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw VoiceInputError.unavailableInput
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0,
                frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else {
            throw VoiceInputError.unavailableInput
        }
        return buffer
    }
}

/// The converter is confined to the audio tap's serial callbacks. Buffers are converted
/// into separately owned storage before being handed to the asynchronous analyzer.
final class VoiceAudioBridge: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let monoFormat: AVAudioFormat
    private let continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
    private let onLevel: (@Sendable (Double) -> Void)?
    private var meterFrames: AVAudioFrameCount = 0
    private var stopped = false

    init(source: AVAudioFormat, destination: AVAudioFormat,
         continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation,
         onLevel: (@Sendable (Double) -> Void)? = nil) throws {
        // USB microphones may provide stereo with an unspecified channel layout.
        // Normalize to known mono PCM before sample-rate conversion for Speech.
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: source.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: mono, to: destination) else {
            throw VoiceInputError.unavailableInput
        }
        self.converter = converter
        self.format = destination
        self.monoFormat = mono
        self.continuation = continuation
        self.onLevel = onLevel
    }

    // Explicit Sendable prevents a main-actor caller from lending its isolation
    // to AVAudioNodeTapBlock's legacy Objective-C callback signature.
    var tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [self] buffer, _ in
            guard !stopped, buffer.frameLength > 0 else { return }
            guard buffer.format.sampleRate == monoFormat.sampleRate else {
                stopped = true; continuation.finish(throwing: VoiceInputError.inputChanged); return
            }
            meterFrames += buffer.frameLength
            if let onLevel, meterFrames >= AVAudioFrameCount(buffer.format.sampleRate / 8) {
                meterFrames = 0
                onLevel(Self.level(of: buffer))
            }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)) + 8
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            let mono: AVAudioPCMBuffer
            do { mono = try normalizedMono(buffer) }
            catch { stopped = true; continuation.finish(throwing: error); return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return mono
            }
            if status == .error {
                stopped = true
                continuation.finish(throwing: error ?? VoiceInputError.unavailableInput as NSError)
            } else if output.frameLength > 0 {
                switch continuation.yield(AnalyzerInput(buffer: output)) {
                case .dropped:
                    stopped = true; continuation.finish(throwing: VoiceInputError.audioBacklog)
                case .terminated: stopped = true
                case .enqueued: break
                @unknown default: break
                }
            }
        }
    }

    private func normalizedMono(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        // The usual mono Float32 route already has the required layout. Conversion
        // consumes it synchronously and yields a separately owned output buffer.
        if buffer.format == monoFormat { return buffer }
        guard let result = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let output = result.floatChannelData?[0], buffer.format.channelCount > 0 else { throw VoiceInputError.unavailableInput }
        result.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let channels = Double(buffer.format.channelCount)
        output.initialize(repeating: 0, count: frames)
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = audio.mData else { throw VoiceInputError.unavailableInput }
            let stride = Int(audio.mNumberChannels)
            func mix<T>(_ type: T.Type, sample: (T) -> Double) throws {
                guard Int(audio.mDataByteSize) / MemoryLayout<T>.stride >= frames * stride else { throw VoiceInputError.unavailableInput }
                let values = data.assumingMemoryBound(to: T.self)
                for frame in 0..<frames {
                    var sum = 0.0
                    for channel in 0..<stride {
                        let value = sample(values[frame * stride + channel])
                        if value.isFinite { sum += value }
                    }
                    output[frame] += Float(sum / channels)
                }
            }
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32: try mix(Float.self) { Double($0) }
            case .pcmFormatFloat64: try mix(Double.self) { $0 }
            case .pcmFormatInt16: try mix(Int16.self) { Double($0) / 32768 }
            case .pcmFormatInt32: try mix(Int32.self) { Double($0) / 2147483648 }
            default: throw VoiceInputError.unavailableInput
            }
        }
        return result
    }

    /// AudioBufferList handles both planar and interleaved capture. Interleaved
    /// audio has one data pointer, even when the format contains several channels.
    static func level(of buffer: AVAudioPCMBuffer) -> Double {
        var peak = 0.0
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = audio.mData else { continue }
            let samples = Int(buffer.frameLength) * Int(audio.mNumberChannels)
            func scan<T>(_ type: T.Type, value: (T) -> Double) {
                let count = min(samples, Int(audio.mDataByteSize) / MemoryLayout<T>.stride)
                let values = data.assumingMemoryBound(to: T.self)
                for index in 0..<count {
                    let sample = abs(value(values[index]))
                    if sample.isFinite { peak = max(peak, sample) }
                }
            }
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32: scan(Float.self) { Double($0) }
            case .pcmFormatFloat64: scan(Double.self) { $0 }
            case .pcmFormatInt16: scan(Int16.self) { Double($0) / 32768 }
            case .pcmFormatInt32: scan(Int32.self) { Double($0) / 2147483648 }
            default: break
            }
        }
        return min(1, max(0, (20 * log10(max(peak, 0.000001)) + 60) / 60))
    }
}
