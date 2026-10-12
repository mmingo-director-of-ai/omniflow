import AppKit
import AVFoundation
import Speech
import Combine
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared: AppModel = {
        OmniFlowVoiceMigration.preparePreferences()
        return AppModel()
    }()
    private let captureLease = OmniFlowInteractionLease(reason: "Dictation and writing")
    private let pointerPauseLease = OmniFlowInteractionLease(reason: "Pointer paused by user")
    private let retryLease = OmniFlowInteractionLease(reason: "Saved dictation insertion")
    private let selectionLease = OmniFlowInteractionLease(reason: "Selected text action")
    private var audioRelease: Task<Void, Never>?
    private var launched = false
    var isActive: Bool { busy }
    var message: String { status }
    @Published var saveHistory = ConversationHistory.shared.enabled {
        didSet { if ConversationHistory.shared.enabled != saveHistory { ConversationHistory.shared.enabled = saveHistory } }
    }

    @Published var settingsTab = "General"
    enum Phase: Equatable { case idle, starting, recording, processing, result, error }
    @Published var phase: Phase = .idle {
        didSet {
            let active = [.starting, .recording, .processing].contains(phase)
            audioRelease?.cancel()
            if active {
                captureLease.begin()
                WakeListener.shared.setDictationActive(true)
            } else {
                // Cancel is synchronous at the UI boundary; physical microphone
                // shutdown is asynchronous. Do not resume wake capture too early.
                audioRelease = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await speech.waitForCleanup()
                    guard !Task.isCancelled, ![.starting, .recording, .processing].contains(phase) else { return }
                    captureLease.end()
                    if !terminating { WakeListener.shared.setDictationActive(false) }
                }
            }
        }
    }
    @Published var locked = false
    @Published var transcript = ""
    @Published var level = 0.0
    /// The pill's live voice spectrum. Observed separately so ~60 updates per
    /// second redraw only the waveform, not every view watching this model.
    let spectrum = DictationSpectrumLevels()
    @Published var elapsed = 0
    @Published var status = "Your voice. A little more free."
    @Published private(set) var microphonePermission = OmniFlowMicrophonePermission.current
    var micReady: Bool { microphonePermission == .allowed }
    @Published private(set) var microphoneInputName = "Checking system input…"
    /// Dictation's own microphone; empty follows the Mac's default input.
    @Published var dictationMicrophoneUID = DictationInputDevice.selectedUID {
        didSet {
            guard dictationMicrophoneUID != oldValue else { return }
            DictationInputDevice.selectedUID = dictationMicrophoneUID
            speech.prewarm(reduceBackgroundNoise: reduceBackgroundNoise)
            microphoneInputName = DictationInputDevice.plan(uid: dictationMicrophoneUID).name
            microphoneIssue = nil
        }
    }
    @Published private(set) var microphoneIssue: String?
    @Published var accessibilityReady = false
    @Published var hotkeyReady = false
    @Published var speechReady = false
    @Published var preparing = false
    @Published var speechStatus = "Checking speech model…"
    @Published var modelStatus = "Checking Apple Intelligence…"
    @Published var modelReady = false
    @Published var languages: [String] = ["en-US"]
    @Published var historySearch = ""
    @Published var managingHistory = false
    @Published var rollingBack = false
    @Published var streamingInField = false
    @Published var focusLabel = ""
    @Published var followFocus = UserDefaults.standard.object(forKey: "followFocus") as? Bool ?? true {
        didSet { UserDefaults.standard.set(followFocus, forKey: "followFocus") }
    }
    var focusFollowsMouse: Bool {
        get { OmniFlowFocusController.shared.enabled }
        set { OmniFlowFocusController.shared.enabled = newValue; objectWillChange.send() }
    }
    @Published var pointerFocusPaused = false {
        didSet {
            if pointerFocusPaused { pointerPauseLease.begin() } else { pointerPauseLease.end() }
        }
    }
    @Published var pendingRetry: DictationEntry?
    @Published var recovering = false
    private var recoveryTask: Task<Void, Never>?
    private var delivering = false
    private var terminating = false
    private var pendingSaves: [UUID: Task<Void, Never>] = [:]
    private var lastRecordingCheckpoint = Date.distantPast
    private var deferredCheckpoint: Task<Void, Never>?
    @Published var historyError = ""
    @Published var historyLoaded = false
    @Published var entries: [DictationEntry] = [] {
        didSet { cachedMetrics = nil }
    }
    @Published var outputStyle = UserDefaults.standard.string(forKey: "outputStyle") ?? "markdown" {
        didSet { UserDefaults.standard.set(outputStyle, forKey: "outputStyle") }
    }
    @Published var writingStyle = WritingStyle(rawValue: UserDefaults.standard.string(forKey: "writingStyle") ?? "apa") ?? .apa {
        didSet { UserDefaults.standard.set(writingStyle.rawValue, forKey: "writingStyle") }
    }
    @Published var translationTargetID = UserDefaults.standard.string(forKey: "translationTarget") ?? "" {
        didSet { UserDefaults.standard.set(translationTargetID, forKey: "translationTarget"); warmTranslation() }
    }
    @Published var translationLanguages: [TranslationLanguage] = []
    @Published var retention = HistoryRetention(rawValue: UserDefaults.standard.object(forKey: "historyRetention") as? Int ?? 30) ?? .thirtyDays {
        didSet { UserDefaults.standard.set(retention.rawValue, forKey: "historyRetention"); applyRetention() }
    }
    @Published var retentionNote = ""
    let dictationPreferences = DictationPreferencesStore()
    let selectionActions = SelectionActionService()
    private let translation = TranslationService()
    private var privacyObservation: AnyCancellable?
    private var overlayObservation: AnyCancellable?
    private var focusSettingsObservation: AnyCancellable?
    private var selectionObservation: AnyCancellable?
    private var insertionObservation: AnyCancellable?
    private var finishWhenReady = false
    private var retentionTimer: Timer?
    private var sessionPreferences: ResolvedDictationPreferences?
    private var sessionReplacements: [PhraseReplacement] = []
    private var sessionTranslationTarget = ""
    private var sessionLocaleID = "en-US"
    @Published var typingWPM = UserDefaults.standard.object(forKey: "typingWPM") as? Double ?? 40 {
        didSet { cachedMetrics = nil; UserDefaults.standard.set(typingWPM, forKey: "typingWPM") }
    }
    private var cachedMetrics: (day: Date, calendar: Calendar, value: UsageMetrics)?
    var metrics: UsageMetrics { metrics(at: .now) }

    func metrics(at now: Date, calendar: Calendar = .current) -> UsageMetrics {
        let day = calendar.startOfDay(for: now)
        if let cachedMetrics, cachedMetrics.day == day, cachedMetrics.calendar == calendar {
            return cachedMetrics.value
        }
        let value = UsageMetrics(entries: entries, typingWPM: typingWPM, now: now, calendar: calendar)
        cachedMetrics = (day, calendar, value)
        return value
    }
    var words: Int { metrics.words }
    var sessions: Int { metrics.dictations }
    @Published var liveTextEnabled = UserDefaults.standard.object(forKey: "liveText") as? Bool ?? true {
        didSet { UserDefaults.standard.set(liveTextEnabled, forKey: "liveText") }
    }
    @Published var appearance = UserDefaults.standard.string(forKey: "omniflow.appearance") ?? "dark" {
        didSet { UserDefaults.standard.set(appearance, forKey: "omniflow.appearance"); applyAppearance() }
    }
    func applyAppearance() { NSApp.appearance = appearance == "system" ? nil : NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua) }
    @Published var sidebarVisible = true
    @Published var settingsError = ""
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    var showDictationBar: Bool {
        get { AppState.shared.quickControlsEnabled }
        set {
            guard AppState.shared.quickControlsEnabled != newValue else { return }
            AppState.shared.quickControlsEnabled = newValue
            onOverlayVisibility?(newValue)
        }
    }
    @Published var openHubOnLaunch = UserDefaults.standard.object(forKey: "openHub") as? Bool ?? true {
        didSet { UserDefaults.standard.set(openHubOnLaunch, forKey: "openHub") }
    }
    @Published var recordingLimit = UserDefaults.standard.object(forKey: "recordingLimit") as? Int ?? 180 {
        didSet { UserDefaults.standard.set(recordingLimit, forKey: "recordingLimit") }
    }
    @Published var selectedPage = "Home"
    @Published var localeID = UserDefaults.standard.string(forKey: "locale") ?? "en-US" {
        didSet { UserDefaults.standard.set(localeID, forKey: "locale"); if oldValue != localeID { speechReady = false; checkSpeech(); warmTranslation() } }
    }
    var cleanupEnabled: Bool { polishMode != .verbatim }
    @Published var polishMode = PolishMode(rawValue: UserDefaults.standard.string(forKey: "polishMode") ?? "")
        ?? ((UserDefaults.standard.object(forKey: "cleanup") as? Bool ?? true) ? .polished : .verbatim) {
        didSet {
            UserDefaults.standard.set(polishMode.rawValue, forKey: "polishMode")
            UserDefaults.standard.set(polishMode != .verbatim, forKey: "cleanup")
        }
    }
    @Published var reduceBackgroundNoise = UserDefaults.standard.object(forKey: "reduceBackgroundNoise") as? Bool ?? true {
        didSet { UserDefaults.standard.set(reduceBackgroundNoise, forKey: "reduceBackgroundNoise"); speech.prewarm(reduceBackgroundNoise: reduceBackgroundNoise) }
    }
    @Published var audioProcessingStatus = "Voice processing will be checked when recording starts."
    private var sessionPolishMode: PolishMode = .polished
    private var sessionVocabulary = ""
    private var preReplaced = false
    @Published var vocabulary = UserDefaults.standard.string(forKey: "vocabulary") ?? "" {
        didSet { UserDefaults.standard.set(vocabulary, forKey: "vocabulary") }
    }
    /// Off unless the user switches it on in Settings › Vocabulary.
    @Published var securityVocabulary = UserDefaults.standard.bool(forKey: VocabularyPack.security.preferenceKey) {
        didSet { UserDefaults.standard.set(securityVocabulary, forKey: VocabularyPack.security.preferenceKey) }
    }
    /// Learns from the user's edits of dictation results; every rule it applies is
    /// listed in Settings › Vocabulary.
    lazy var learning: CorrectionLearningModel = CorrectionLearningModel { [weak self] word in
        guard let self else { return true }
        return self.spelling.isKnownWord(word, locale: Locale(identifier: self.localeID))
    }
    private let spelling = AppleSpellingService()
    /// User terms, enabled packs, replacement targets and applied learned rules:
    /// what the recognizer and cleanup are given. `vocabulary` stays the user's own list.
    var dictationVocabulary: DictationVocabulary {
        DictationVocabulary(userVocabulary: vocabulary, enabledPacks: securityVocabulary ? [.security] : [],
                            replacements: dictationPreferences.replacements,
                            learnedReplacements: learning.learnedReplacements, learnedTerms: learning.learnedTerms)
    }
    var effectiveVocabulary: String { dictationVocabulary.text }
    var onOpenSettings: (() -> Void)?
    var onOverlayVisibility: ((Bool) -> Void)?
    var onOpenHub: (() -> Void)?
    let speech = SpeechService()
    let cleanup = CleanupService()
    let insertion = InsertionService()
    let hotkey = HotkeyService()
    let history = HistoryStore(directory: NotchLeeStorage.root.appendingPathComponent("Dictations", isDirectory: true))
    private var recordingStarted: Date?
    private var captureSeconds: Double?
    private var currentEntry: DictationEntry?
    private var liveSession: InsertionService.LiveSession?
    private var liveTask: Task<Void, Never>?
    private var finalLiveTask: Task<InsertionService.LiveOutcome, Never>?
    private var rollbackTask: Task<Void, Never>?
    private var liveDesired = ""
    private var target: InsertionService.Target?
    private var practiceSession = false
    var isLocalDictationSession: Bool { practiceSession }
    private var hasLiveMutation = false
    private lazy var focusTracker = FocusTracker<InsertionService.Target> { [weak self] in self?.insertion.capture() }
    private var sessionID = UUID()
    private var operation: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var permissionTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var speechCheck = UUID()
    var busy: Bool { selectionActions.busy || recovering || rollingBack || [.starting, .recording, .processing].contains(phase) }
    var canRecord: Bool { micReady && speechReady && !preparing && historyLoaded && !managingHistory && !terminating }
    var latest: DictationEntry? { entries.first }

    func launch() {
        guard !launched else { return }; launched = true
        applyAppearance()
        // One source of truth for every surface. Forward invalidation only:
        // writing a delayed snapshot back can undo a more recent user change.
        overlayObservation = AppState.shared.$quickControlsEnabled.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
        focusSettingsObservation = OmniFlowFocusSettings.shared.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
        privacyObservation = ConversationHistory.shared.$enabled.removeDuplicates().sink { [weak self] enabled in
            guard let self, self.saveHistory != enabled else { return }; self.saveHistory = enabled
        }
        insertionObservation = insertion.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        selectionActions.canStart = { [weak self] in
            guard let self else { return false }
            return !self.recovering && !self.rollingBack && !self.managingHistory && !self.terminating
                && ![.starting, .recording, .processing].contains(self.phase)
        }
        selectionObservation = selectionActions.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if selectionActions.busy { selectionLease.begin() } else { selectionLease.end() }
            }
        }
        Task { translationLanguages = await translation.supportedLanguages() }
        warmTranslation()
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyRetention() }
        }
        retentionTimer?.tolerance = 60
        Task {
            do {
                try await OmniFlowVoiceMigration.importHistory(into: history)
                let loaded = try await history.load()
                entries = loaded.entries
                if loaded.unreadableCount > 0 { historyError = "\(loaded.unreadableCount) history file(s) could not be read. Other transcripts are intact." }
                historyLoaded = true
                applyRetention()
            } catch { historyError = "History could not be opened: " + error.localizedDescription }
        }
        hotkey.onAction = { [weak self] action in self?.handle(action) }
        hotkey.onUserInteraction = { [weak self] kind in
            self?.insertion.userInteracted(kind)
            OmniFlowFocusController.shared.cancelPendingInputFocus()
        }
        hotkey.onFailure = { [weak self] in
            guard let self, [.starting, .recording, .processing].contains(phase) else { return }
            cancel(message: "Keyboard monitoring restarted. Your transcript is retained; try again.")
        }
        refreshPermissions()
        checkSpeech()
        Task {
            let locales = await SpeechTranscriber.supportedLocales
            languages = locales.map(\.identifier).sorted()
            if !languages.contains(localeID) { languages.insert(localeID, at: 0) }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        permissionTimer?.tolerance = 0.5
        let center = NSWorkspace.shared.notificationCenter
        for notification in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancel(message: "Recording stopped because your Mac is sleeping or the session is inactive.") }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] notification in
            // Notification delivery explicitly uses the main queue. Ignore other
            // AVAudioEngines (playback, sounds, unrelated capture services).
            let changedEngine = (notification.object as? AVAudioEngine).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, self.phase == .recording, self.speech.ownsEngine(changedEngine) else { return }
                self.fail("Microphone changed. Your partial transcript is available in Recent.")
            }
        })
    }
    func reloadSyncedHistory() async {
        guard !busy else { return }
        do { entries = try await history.load().entries }
        catch { historyError = "History could not be refreshed: " + error.localizedDescription }
    }

    func refreshPermissions() {
        let microphone = OmniFlowMicrophonePermission.current
        let accessibility = insertion.isTrusted
        if microphonePermission != microphone {
            microphonePermission = microphone
            if !micReady { microphoneIssue = nil }
        }
        let inputName = DictationInputDevice.plan().name
        if microphoneInputName != inputName { microphoneInputName = inputName; microphoneIssue = nil }
        if accessibilityReady != accessibility { accessibilityReady = accessibility }
        let keyboard: Bool
        if accessibility { keyboard = hotkey.start() }
        else { if hotkey.isRunning { hotkey.stop() }; keyboard = false }
        if hotkeyReady != keyboard { hotkeyReady = keyboard }
        if busy && !micReady {
            fail(microphonePermission.guidance + " Recording stopped; any recognized text is retained.")
        } else if busy && !accessibilityReady && target != nil {
            fail("Accessibility access was removed. Recording stopped; any recognized text is retained. Allow OmniFlow in Privacy & Security → Accessibility to paste into other apps.")
        }
        let availability = cleanup.availability, ready = cleanup.isAvailable
        if modelStatus != availability { modelStatus = availability }
        if modelReady != ready { modelReady = ready }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            settingsError = SMAppService.mainApp.status == .requiresApproval ? "Allow OmniFlow in Login Items to finish setup." : ""
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { settingsError = "Login item could not be changed: " + error.localizedDescription }
    }
    func requestMicrophone() {
        Task {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else if !micReady { openSettings("Privacy_Microphone") }
            refreshPermissions()
        }
    }
    func requestAccessibility() {
        insertion.requestPermission()
        openSettings("Privacy_Accessibility")
    }
    func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
    func openKeyboard() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    func openSoundInput() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input") { NSWorkspace.shared.open(url) }
    }
    func showVoiceSettings() {
        selectedPage = "Settings"; settingsTab = "Dictation"; onOpenHub?()
    }
    var recordingReadinessMessage: String? {
        if !micReady { return microphonePermission.guidance }
        if preparing { return "The speech model is still being prepared. Wait for it to finish in Dictation settings." }
        if !speechReady { return speechStatus }
        if !historyLoaded { return "Local history is still loading. Try again when it is ready." }
        if managingHistory { return "Wait for the current history operation to finish, then try again." }
        if terminating { return "OmniFlow is closing." }
        return nil
    }
    func checkSpeech(download: Bool = false) {
        guard !busy else { return }
        let token = UUID(); speechCheck = token
        let locale = Locale(identifier: localeID)
        preparing = true
        speechStatus = download ? "Preparing Apple’s speech model…" : "Checking speech model…"
        Task {
            do {
                try await speech.prepare(locale: locale, download: download)
                guard speechCheck == token else { return }
                speechReady = true; speechStatus = "Downloaded · works offline"
                speech.prewarm(reduceBackgroundNoise: reduceBackgroundNoise)
            } catch {
                guard speechCheck == token else { return }
                speechReady = false; speechStatus = error.localizedDescription
            }
            preparing = false
        }
    }
    private func handle(_ action: ShortcutMachine.Action) {
        switch action {
        case .start:
            if phase == .recording && locked { finish() } else { begin(practice: false) }
        case .lock: locked = true
        case .finish: finish()
        case .cancel: cancel()
        }
    }
    /// Translation is enabled when an output language is chosen. Warming only
    /// touches installed pairs and never downloads.
    private func warmTranslation() {
        guard !translationTargetID.isEmpty else { return }
        TranslationWarmup.shared.request(source: Locale.Language(identifier: localeID), target: Locale.Language(identifier: translationTargetID))
    }

    func begin(practice: Bool) {
        let hotkeyDown = Date()
        guard !busy else { return }
        resetTask?.cancel()
        VoiceAssistant.shared.cancel()
        pendingRetry = nil
        guard canRecord else {
            hotkey.reset(); phase = .error; status = recordingReadinessMessage ?? "Open Dictation settings to finish setup."
            showVoiceSettings(); return
        }
        finishWhenReady = false
        practiceSession = practice; hasLiveMutation = false
        sessionID = UUID(); let token = sessionID
        startTimeline = DictationStartTimeline(hotkeyDown: hotkeyDown)
        if practice { hotkey.lock() }
        recordingStarted = nil; captureSeconds = nil; microphoneIssue = nil
        phase = .starting; locked = practice; transcript = ""; level = 0; spectrum.clear(); elapsed = 0
        status = "Opening microphone…"
        // The pill is drawn on the next main-loop turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionID == token else { return }
            self.startTimeline?.mark(.pillShown)
        }
        // Open the microphone before anything else: `Task.immediate` runs synchronously
        // up to the first real suspension, which is after capture has been handed to its
        // actor. The analyzer prepares in parallel; audio is buffered meanwhile.
        operation = Task.immediate { [weak self] in
            guard let self else { return }
            do {
                try await speech.start(reduceBackgroundNoise: reduceBackgroundNoise, vocabulary: effectiveVocabulary, onText: { [weak self] text in
                    guard let self, self.sessionID == token else { return }; self.transcript = text
                    if !text.isEmpty { self.startTimeline?.mark(.firstPartial); self.finishStartTimeline() }
                    self.queueCheckpoint(raw: text, state: .recording, note: "Listening")
                    self.queueLive(text, token: token)
                }, onLevel: { [weak self] level in
                    guard let self, self.sessionID == token else { return }; self.level = level
                    if level > 0.05 && microphoneIssue != nil { microphoneIssue = nil }
                }, onSpectrum: { [weak self] bands, peaks in
                    guard let self, self.sessionID == token, self.phase == .recording || self.phase == .starting else { return }
                    self.spectrum.update(bands: bands, peaks: peaks)
                }, onStage: { [weak self] stage, at in
                    guard let self, self.sessionID == token else { return }
                    switch stage {
                    case .firstBuffer: self.startTimeline?.mark(.firstBuffer, at: at)
                    case .analyzerReady: self.startTimeline?.mark(.analyzerReady, at: at)
                    case .captureRunning(let reused): self.startTimeline?.mark(.captureRunning, at: at); self.startTimeline?.reusedEngine = reused
                    }
                }, onError: { [weak self] error in
                    guard let self, self.sessionID == token else { return }; self.fail(error)
                })
                guard sessionID == token, !Task.isCancelled else { return }
                audioProcessingStatus = speech.voiceProcessingStatus
                phase = .recording; recordingStarted = .now
                status = target.map { "Dictating to \($0.appName)" } ?? (practice ? "Practice · your transcript stays here" : insertion.captureProblem)
                if finishWhenReady { finish(); return }
                startClock(token)
            } catch {
                guard sessionID == token, !Task.isCancelled else { return }
                fail(error.localizedDescription)
            }
        }
        focusTracker.stop()
        target = practice ? nil : insertion.capture()
        sessionPreferences = dictationPreferences.resolve(bundleID: target?.bundleID, defaultWritingStyle: writingStyle, defaultOutputStyle: outputStyle)
        // The user's own rules first, then learned ones; earlier rules win overlaps.
        sessionReplacements = dictationPreferences.replacements + learning.learnedReplacements.map { PhraseReplacement(phrase: $0.from, replacement: $0.to) }
        cleanup.stylePreferences = learning.learnedStyles
        preReplaced = false
        sessionTranslationTarget = translationTargetID
        sessionLocaleID = localeID
        sessionPolishMode = polishMode
        sessionVocabulary = effectiveVocabulary
        // Load the cleanup model while the user speaks.
        cleanup.prewarm(locale: Locale(identifier: sessionLocaleID), structured: (sessionPreferences?.outputStyle ?? outputStyle) == "markdown",
                        writingStyle: sessionPreferences?.writingStyle ?? writingStyle, mode: sessionPolishMode)
        focusLabel = practice ? "Practice · no paste" : target.map { "Destination: " + $0.appName } ?? "Click a text field to choose a destination"
        if !practice && followFocus {
            focusTracker.onChange = { [weak self] destination in
                guard let self else { return }
                self.focusLabel = destination.map { "Destination: " + $0.appName } ?? "No editable field focused"
            }
            focusTracker.start()
        }
        liveSession = liveTextEnabled ? target.flatMap { insertion.beginLive($0) } : nil
        liveDesired = ""; streamingInField = liveSession != nil
        currentEntry = DictationEntry(raw: "", text: "", note: "Listening", destination: target?.appName ?? "Practice", state: .recording)
        armDeadline(seconds: 12, token: token) { [weak self] in
            guard self?.phase == .starting else { return }; self?.fail("The microphone took too long to start. Please try again.")
        }
    }

    /// Start-latency timeline for the current dictation; sent once, at the first
    /// partial transcript or when the dictation ends, whichever comes first.
    private var startTimeline: DictationStartTimeline?
    private func finishStartTimeline() {
        guard let timeline = startTimeline else { return }
        startTimeline = nil
        timeline.send()
    }
    private func startClock(_ token: UUID) {
        watchdog?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.sessionID == token, self.phase == .recording else { return }
                self.elapsed += 1
                if Date().timeIntervalSince(speech.lastAudioAt ?? recordingStarted ?? .now) > 4 {
                    let issue = "The microphone stopped delivering audio. Check your Mac's input and try again."
                    microphoneIssue = issue
                    fail(issue)
                    return
                }
                if elapsed >= 8 && !speech.heardSound && transcript.isEmpty {
                    let warning = "No microphone sound from \(speech.microphoneName). Check mute or your Mac's sound input."
                    if microphoneIssue != warning { microphoneIssue = warning }
                    if status != warning { status = warning }
                } else if status.hasPrefix("No microphone sound") {
                    status = target.map { "Dictating to \($0.appName)" } ?? (practiceSession ? "Practice · your transcript stays here" : insertion.captureProblem)
                }
                if self.elapsed >= self.recordingLimit { self.finish(); return }
            }
        }
    }
    func lockRecording() { if phase == .recording || phase == .starting { locked = true; hotkey.lock() } }
    func finish() {
        if phase == .starting { finishWhenReady = true; return }
        guard phase == .recording else { return }
        if !practiceSession && followFocus && !hasLiveMutation {
            // Keep following focus through cleanup; capture immediately before the paste.
            liveSession = nil; streamingInField = false
        } else { focusTracker.stop() }
        captureSeconds = recordingStarted.map { Date().timeIntervalSince($0) }
        hotkey.processing()
        phase = .processing; status = "Finding the right words…"; level = 0; spectrum.clear()
        queueCheckpoint(raw: transcript, state: .processing, note: "Processing on this Mac")
        clockTask?.cancel(); let token = sessionID
        armDeadline(seconds: 15, token: token) { [weak self] in self?.fail("Transcription took too long. Your partial transcript is in Recent.") }
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                finishStartTimeline()
                let raw = try await speech.finish()
                guard sessionID == token, !Task.isCancelled else { return }
                watchdog?.cancel()
                await liveTask?.value
                guard sessionID == token, !Task.isCancelled else { return }
                guard !raw.isEmpty else {
                    let issue = speech.heardSound
                        ? "Audio reached OmniFlow, but no words were recognized. Check the spoken language and try again."
                        : "No microphone sound from \(speech.microphoneName). Check mute or your Mac's sound input."
                    microphoneIssue = issue
                    fail(issue)
                    return
                }
                transcript = raw
                if let entry = checkpoint(raw: raw, state: .processing, note: "Preparing final transcript") {
                    try await persistEntry(entry)
                }
                guard sessionID == token, !Task.isCancelled else { return }
                if sessionPolishMode != .verbatim {
                    status = "A little polish. All on your Mac."
                    // Long dictations are edited in pieces; give them time in proportion
                    // rather than pasting the raw text because a fixed budget ran out.
                    let words = raw.split(whereSeparator: \.isWhitespace).count
                    let cleanupSeconds = (sessionPolishMode == .polished || ChartFormattingService.isExplicitRequest(raw) ? 25 : 10) + min(35, words / 25)
                    armDeadline(seconds: cleanupSeconds, token: token) { [weak self] in
                        guard let self else { return }
                        self.operation?.cancel()
                        self.sessionID = UUID(); let fallbackToken = self.sessionID
                        self.preReplaced = false
                        self.operation = Task { await self.finalizeOutput(raw: raw, result: CleanupService.fallback(raw, locale: Locale(identifier: self.sessionLocaleID), reason: "cleanup timed out", mode: self.sessionPolishMode), token: fallbackToken) }
                    }
                    // Explicit replacements fix known mishearings before cleanup sees them
                    // ("ICs" → "IOCs"), so the model and its guards start from the right words.
                    let replacedRaw = PhraseReplacements.apply(raw, rules: sessionReplacements)
                    preReplaced = true
                    let result = await cleanup.clean(replacedRaw, locale: Locale(identifier: sessionLocaleID), vocabulary: sessionVocabulary, structured: (sessionPreferences?.outputStyle ?? outputStyle) == "markdown", writingStyle: sessionPreferences?.writingStyle ?? writingStyle, mode: sessionPolishMode) { [weak self] preview in
                        guard let self, self.sessionID == token else { return }
                        self.transcript = preview
                        // Model tokens are provisional. Show them in our UI; only the
                        // validated complete cleanup is allowed to replace text externally.
                    }
                    guard sessionID == token, !Task.isCancelled else { return }
                    watchdog?.cancel()
                    await finalizeOutput(raw: raw, result: result, token: token)
                } else {
                    await finalizeOutput(raw: raw, result: .init(text: raw, note: "Original transcript · verbatim"), token: token)
                }
            } catch {
                guard sessionID == token, !Task.isCancelled else { return }; fail(error.localizedDescription)
            }
        }
    }
    private func finalizeOutput(raw: String, result: CleanupResult, token: UUID) async {
        guard sessionID == token, !Task.isCancelled else { return }
        // Apply again for anything cleanup reintroduced, except rules whose output
        // contains their own phrase ("API" → "API key"), which would double.
        let rules = preReplaced ? sessionReplacements.filter { !$0.replacement.localizedCaseInsensitiveContains($0.phrase) } : sessionReplacements
        let replaced = PhraseReplacements.apply(result.text, rules: rules)
        let note = result.note + (replaced == result.text ? "" : " · Custom replacements applied")
        // Edits describe dictated → delivered text, so they are recomputed when replacements or layout change it.
        let refused = result.edits.filter { !$0.accepted }.map { RewriteValidation.Refusal(original: $0.original, replacement: $0.replacement, reason: $0.refusalReason ?? "") }
        func edits(for text: String) -> [CleanupEdit] {
            text == result.text || result.edits.isEmpty ? result.edits : CleanupEdits.compute(source: raw, result: text, refused: refused)
        }
        var prepared = CleanupResult(text: replaced, note: note, edits: edits(for: replaced))
        if (sessionPreferences?.outputStyle ?? outputStyle) == AgentLayout.outputStyle {
            status = "Laying it out for your agent…"
            let layout = await AgentLayout.format(replaced)
            guard sessionID == token, !Task.isCancelled else { return }
            prepared = CleanupResult(text: layout.text, note: note + (layout.fallback == nil ? " · Laid out for agents" : " · Laid out for agents, one sentence per line"),
                                     edits: edits(for: layout.text))
        }
        guard !sessionTranslationTarget.isEmpty else { await deliver(raw: raw, result: prepared, token: token); return }
        status = "Translating on your Mac…"
        armDeadline(seconds: 20, token: token) { [weak self] in
            guard let self else { return }
            self.operation?.cancel()
            self.sessionID = UUID(); let fallbackToken = self.sessionID
            self.operation = Task {
                await self.deliver(raw: raw, result: .init(text: prepared.text, note: prepared.note + " · Translation timed out; source preserved", edits: prepared.edits), token: fallbackToken)
            }
        }
        let translated = await translation.translate(replaced, source: Locale.Language(identifier: sessionLocaleID), target: Locale.Language(identifier: sessionTranslationTarget))
        guard sessionID == token, !Task.isCancelled else { return }
        watchdog?.cancel()
        await deliver(raw: raw, result: .init(text: translated.text, note: note + " · " + translated.note), token: token)
    }
    private func deliver(raw: String, result: CleanupResult, token: UUID) async {
        guard sessionID == token, !Task.isCancelled else { return }
        delivering = true
        defer { delivering = false }
        transcript = result.text
        await liveTask?.value
        guard sessionID == token, !Task.isCancelled else { return }
        if followFocus && !practiceSession && !hasLiveMutation {
            target = focusTracker.freeze()
            focusLabel = target.map { "Paste to " + $0.appName } ?? "No destination · saved to history"
            currentEntry?.destination = target?.appName ?? "No destination"
        }
        var note = result.note
        // Durable final text comes BEFORE the external side effect of insertion.
        currentEntry?.edits = result.edits.isEmpty ? nil : result.edits
        if let saved = checkpoint(raw: raw, text: result.text, state: .ready, note: note) {
            do { try await persistEntry(saved) }
            catch {
                guard sessionID == token else { return }
                historyError = "Could not save history: " + error.localizedDescription
                focusTracker.stop()
                status = "History could not be saved. Copy your transcript."; phase = .result; hotkey.reset(); return
            }
        }
        guard sessionID == token, !Task.isCancelled else { return }
        var delivered = false
        var insertionVerified = false
        if let sink = noteSink {
            noteSink = nil; dictatingIntoNote = false
            sink(result.text)
            delivered = true; insertionVerified = true
            currentEntry?.destination = "Note"
            status = "Added to your note"
        }
        if !delivered, let live = liveSession {
            let mutation = Task { await insertion.updateLive(live, text: result.text) }
            finalLiveTask = mutation
            let outcome = await mutation.value
            guard sessionID == token, !Task.isCancelled else { return }
            switch outcome {
            case .written: delivered = true; insertionVerified = true; status = "Added to \(live.target.appName)"
            case .unsupported: liveSession = nil
            case .changed: target = nil; liveSession = nil; status = "Draft changed · transcript saved"; note += " · Draft changed during live dictation. Check it before copying."
            }
        }
        if !delivered, let target {
            do {
                let outcome = try await insertion.insert(result.text, into: target)
                guard sessionID == token, !Task.isCancelled else { return }
                delivered = true
                insertionVerified = outcome == .inserted
                note += insertionVerified ? " · Insertion verified" : " · Paste shortcut sent; destination has not confirmed insertion"
                status = outcome == .inserted ? "Added to \(target.appName)" : "Paste sent to \(target.appName)"
            } catch {
                guard sessionID == token, !Task.isCancelled else { return }
                status = "Ready to copy"; note += " · " + error.localizedDescription
            }
        } else if !delivered { status = "Ready to copy"; note += " · " + insertion.captureProblem }
        if let entry = checkpoint(raw: raw, text: result.text, state: delivered ? (insertionVerified ? .delivered : .pasteSent) : .needsCopy, note: note) {
            do { try await persistEntry(entry) }
            catch { historyError = "Final text was saved, but its delivery status could not be updated." }
        }
        guard sessionID == token, !Task.isCancelled else { return }
        liveSession = nil; liveTask = nil; finalLiveTask = nil; streamingInField = false
        phase = .result; hotkey.reset()
        if delivered { scheduleReset() }
    }
    func cancel(message: String = "Dictation cancelled") {
        noteSink = nil; dictatingIntoNote = false
        if recovering { recoveryTask?.cancel(); status = "Stopping saved-text retry…"; return }
        if selectionActions.busy { selectionActions.cancel(); return }
        guard !rollingBack else { return }
        let recoveryText = busy ? (currentEntry?.raw.isEmpty == false ? currentEntry!.raw : transcript) : ""
        if busy && !transcript.isEmpty { queueCheckpoint(raw: currentEntry?.raw ?? transcript, text: currentEntry?.text ?? "", state: .cancelled, note: message) }
        currentEntry = nil
        focusTracker.stop(); focusLabel = ""
        let oldLive = liveSession; let oldLiveTask = liveTask; let oldFinalLiveTask = finalLiveTask
        finalLiveTask = nil; streamingInField = false
        liveTask?.cancel(); liveTask = nil; liveSession = nil
        sessionID = UUID(); let cancellationToken = sessionID
        operation?.cancel(); watchdog?.cancel(); clockTask?.cancel(); resetTask?.cancel()
        finishStartTimeline()
        speech.cancel(); hotkey.reset(); target = nil; locked = false; level = 0; spectrum.clear()
        transcript = recoveryText; phase = recoveryText.isEmpty ? .idle : .result; status = message
        if let oldLive {
            rollingBack = true
            phase = .processing
            rollbackTask = Task {
                await oldLiveTask?.value
                _ = await oldFinalLiveTask?.value
                await insertion.rollbackLive(oldLive)
                if sessionID == cancellationToken { rollingBack = false; phase = transcript.isEmpty ? .idle : .result; hotkey.reset() }
            }
        }
    }
    private func fail(_ message: String) {
        noteSink = nil; dictatingIntoNote = false
        let recovery = currentEntry?.raw.isEmpty == false ? currentEntry!.raw : transcript
        if !transcript.isEmpty { queueCheckpoint(raw: currentEntry?.raw.isEmpty == false ? currentEntry!.raw : transcript, text: currentEntry?.text ?? "", state: .failed, note: "Incomplete · " + message) }
        currentEntry = nil
        cancel(message: message)
        transcript = recovery; phase = .error
    }
    private func armDeadline(seconds: Int, token: UUID, action: @escaping @MainActor () -> Void) {
        watchdog?.cancel()
        watchdog = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard sessionID == token, !Task.isCancelled else { return }; action()
        }
    }
    private func scheduleReset() {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.phase == .result else { return }; self.phase = .idle
        }
    }
    /// Where a note dictation goes instead of being typed into another app.
    private var noteSink: ((String) -> Void)?
    /// True while the current dictation will be added to an OmniFlow note.
    @Published private(set) var dictatingIntoNote = false

    /// Hands-free dictation into a note: nothing is typed into other apps; the
    /// polished text is handed to `deliver` and saved to history as "Note".
    func dictateIntoNote(_ deliver: @escaping (String) -> Void) {
        guard !busy else { return }
        noteSink = deliver
        dictatingIntoNote = true
        begin(practice: true)
        lockRecording()
    }

    func toggleHandsFree() {
        if phase == .recording || phase == .starting { finish() }
        else if !busy { begin(practice: false); lockRecording() }
    }
    func togglePointerFocusPause() { pointerFocusPaused.toggle() }
    func prepareRetry(_ entry: DictationEntry) {
        guard !busy, !managingHistory, !entry.displayText.isEmpty else { return }
        resetTask?.cancel()
        pendingRetry = entry
        phase = .idle
        status = "Focus a text field, then choose Paste saved text. Retrying can duplicate text if it already arrived."
        onOverlayVisibility?(true)
    }
    func dismissRetry() { guard !recovering else { return }; pendingRetry = nil }
    func pastePendingRetry() {
        guard !busy, !managingHistory, let selected = pendingRetry,
              let latest = entries.first(where: { $0.id == selected.id }) else { return }
        guard let destination = insertion.capture() else {
            status = insertion.captureProblem
            return
        }
        recovering = true; delivering = true
        retryLease.begin()
        status = "Pasting saved text to " + destination.appName
        recoveryTask = Task {
            defer { recovering = false; delivering = false; recoveryTask = nil; retryLease.end() }
            var entry = latest
            entry.revision += 1; entry.state = .ready
            entry.destination = destination.appName
            entry.note = "Explicit retry prepared; delivery not yet confirmed"
            do {
                try await persistEntry(entry)
                if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
                try Task.checkCancellation()
                let outcome = try await insertion.insert(entry.displayText, into: destination)
                entry.state = outcome == .inserted ? .delivered : .pasteSent
                entry.note = outcome == .inserted ? "Retried · insertion verified" : "Retried · paste sent; destination has not confirmed insertion"
                pendingRetry = nil
                status = outcome == .inserted ? "Added to " + destination.appName : "Paste sent to " + destination.appName
            } catch {
                entry.state = .needsCopy
                entry.note = "Retry stopped · " + error.localizedDescription
                status = "Saved text is still available · " + error.localizedDescription
            }
            entry.revision += 1
            do { try await persistEntry(entry) }
            catch { historyError = "Could not update retry status: " + error.localizedDescription }
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
        }
    }
    func copy(_ text: String) { OmniFlowClipboard.copy(text) }
    private func queueLive(_ text: String, token: UUID) {
        if followFocus && !practiceSession && !hasLiveMutation && liveTask == nil && phase == .recording {
            // Before the first live write, use the field selected now, not at microphone start.
            target = insertion.capture()
            liveSession = liveTextEnabled ? target.flatMap { insertion.beginLive($0) } : nil
            streamingInField = liveSession != nil
            currentEntry?.destination = target?.appName ?? "No destination"
        }
        guard liveSession != nil, !text.isEmpty else { return }
        liveDesired = text
        guard liveTask == nil else { return }
        liveTask = Task { [weak self] in
            guard let self else { return }
            while sessionID == token, !Task.isCancelled, let live = liveSession {
                let desired = liveDesired
                // Once any mutation is requested, never redirect this transcript elsewhere.
                hasLiveMutation = true; focusTracker.stop()
                focusLabel = "Live text: " + live.target.appName
                let result = await insertion.updateLive(live, text: desired)
                guard sessionID == token, !Task.isCancelled else { return }
                if result == .unsupported { liveSession = nil; streamingInField = false; break }
                if result == .changed {
                    liveSession = nil; target = nil; streamingInField = false
                    status = "Draft changed · dictation continues in history"
                    break
                }
                if liveDesired == desired { break }
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            }
            if sessionID == token { liveTask = nil }
        }
    }
    private func checkpoint(raw: String, text: String? = nil, state: DictationEntry.State, note: String) -> DictationEntry? {
        // A later state always supersedes a throttled live checkpoint.
        if state != .recording { deferredCheckpoint?.cancel(); deferredCheckpoint = nil }
        guard !raw.isEmpty, var entry = currentEntry else { return nil }
        entry.raw = raw; if let text { entry.text = text }
        entry.state = state; entry.note = note; entry.revision += 1
        entry.durationSeconds = captureSeconds ?? recordingStarted.map { Date().timeIntervalSince($0) }
        currentEntry = entry
        if saveHistory {
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
            else { entries.insert(entry, at: 0) }
        }
        return entry
    }
    private func persistEntry(_ entry: DictationEntry) async throws {
        if saveHistory { try await history.save(entry) }
    }
    /// Live partial checkpoints are written at most every 1.5 s; the latest one
    /// lands at the end of the window. Other states are written immediately.
    private func queueCheckpoint(raw: String, text: String? = nil, state: DictationEntry.State, note: String) {
        if state == .recording {
            deferredCheckpoint?.cancel(); deferredCheckpoint = nil
            let wait = 1.5 - Date().timeIntervalSince(lastRecordingCheckpoint)
            if wait > 0 {
                let token = sessionID
                deferredCheckpoint = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard let self, !Task.isCancelled, sessionID == token else { return }
                    deferredCheckpoint = nil
                    queueCheckpoint(raw: raw, text: text, state: state, note: note)
                }
                return
            }
            lastRecordingCheckpoint = .now
        }
        guard let entry = checkpoint(raw: raw, text: text, state: state, note: note) else { return }
        guard saveHistory else { return }
        let writeID = UUID()
        pendingSaves[writeID] = Task {
            do { try await persistEntry(entry) }
            catch { historyError = "Could not save the latest transcript: " + error.localizedDescription }
            pendingSaves.removeValue(forKey: writeID)
        }
    }
    /// Save the user's edit of a dictation's result and learn from it (only when
    /// history is kept: the pair is transcript text).
    func editEntry(_ entry: DictationEntry, text: String) {
        let edited = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !edited.isEmpty, edited != entry.displayText else { return }
        var updated = entry
        updated.text = edited; updated.revision += 1
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = updated }
        if pendingRetry?.id == entry.id { pendingRetry = updated }
        guard saveHistory else { return }
        learning.record(entryID: entry.id, raw: entry.raw, cleaned: entry.displayText, final: edited)
        Task {
            do { try await persistEntry(updated) }
            catch { historyError = "Could not save your edit: " + error.localizedDescription }
        }
    }
    func applyRetention() {
        guard historyLoaded, !managingHistory else { return }
        managingHistory = true
        let excluded = Set([currentEntry?.id, pendingRetry?.id].compactMap { $0 })
        Task {
            defer { managingHistory = false }
            do {
                let outcome = try await history.applyRetention(retention, excludingIDs: excluded)
                let removed = Set(outcome.trashedIDs)
                entries.removeAll { removed.contains($0.id) }
                if retention != .forever {
                    learning.removePairs(olderThan: Date().addingTimeInterval(-Double(retention.rawValue) * 86_400))
                }
                retentionNote = outcome.failedIDs.isEmpty
                    ? (removed.isEmpty ? "Retention checked. Recovery drafts are kept." : "Moved \(removed.count) completed dictation(s) to Trash.")
                    : "Some expired records could not be moved to Trash; they are still available."
            } catch { retentionNote = "Retention could not run: " + error.localizedDescription }
        }
    }
    func clearHistory() {
        guard !busy, !managingHistory else { return }
        managingHistory = true
        let alert = NSAlert()
        alert.messageText = "Move transcript history to Trash?"
        alert.informativeText = "Original and cleaned transcripts will move to the Mac’s Trash. Your dictionary and preferences will stay."
        alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, !busy else { managingHistory = false; return }
        let ids = entries.map(\.id)
        Task {
            do {
                try await history.moveToTrash(ids: ids)
                entries.removeAll { ids.contains($0.id) }; pendingRetry = nil; transcript = ""; phase = .idle; currentEntry = nil
                learning.removePairs()
            } catch { historyError = "Some history could not be moved: " + error.localizedDescription }
            managingHistory = false
        }
    }
    func deleteEntry(_ entry: DictationEntry) {
        guard !busy, !managingHistory else { return }
        let alert = NSAlert()
        alert.messageText = "Move this dictation to Trash?"
        alert.informativeText = "The original and processed text can be recovered from the Mac’s Trash."
        alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, !busy else { return }
        managingHistory = true
        Task {
            defer { managingHistory = false }
            do {
                try await history.moveToTrash(ids: [entry.id])
                entries.removeAll { $0.id == entry.id }
                if pendingRetry?.id == entry.id { pendingRetry = nil }
                learning.removePair(entryID: entry.id)
            } catch { historyError = "Could not move this dictation to Trash. Its text is still available." }
        }
    }
    func exportHistory() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "OmniFlow-dictations.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { historyError = "History could not be exported. Your saved dictations are unchanged." }
    }
    func revealHistory() { NSWorkspace.shared.open(history.directory) }
    func shutdown() async {
        terminating = true
        selectionActions.cancel()
        retentionTimer?.invalidate()
        recoveryTask?.cancel()
        await recoveryTask?.value
        cancel(); permissionTimer?.invalidate(); hotkey.stop()
        await speech.waitForCleanup()
        await rollbackTask?.value
        audioRelease?.cancel()
        pointerPauseLease.end(); captureLease.end(); selectionLease.end(); retryLease.end()
        let outstanding = Array(pendingSaves.values)
        for task in outstanding { await task.value }
    }
}
