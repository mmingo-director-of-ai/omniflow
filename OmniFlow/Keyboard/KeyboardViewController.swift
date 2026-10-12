import SwiftUI
import UIKit

/// The OmniFlow keyboard is a dictation switcher, not a typing keyboard:
/// switching to it starts listening, tapping the button stops, the text goes
/// in at the cursor and it hands back to the previous keyboard (Apple's).
/// Keyboards can't record, so the app does; see KeyboardBridge.
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var observation: KeyboardBridge.Observation?

    override func viewDidLoad() {
        super.viewDidLoad()
        model.controller = self
        let host = UIHostingController(rootView: KeyboardView(model: model))
        // The system draws the keyboard backdrop; SwiftUI must not add its own or extra insets.
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        host.sizingOptions = []
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        // A preferred, not required, height: hosts such as Messages size the
        // keyboard themselves, and a required constant fights them.
        let height = view.heightAnchor.constraint(equalToConstant: KeyboardView.height)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
        host.didMove(toParent: self)
        observation = KeyboardBridge.observe { [weak self] in self?.refresh() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.arrivedForDictation = false
        refresh(autoStart: model.quickDictation)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Text can only be inserted while this keyboard is up; drop a dictation left running.
        if model.state.phase == .listening { model.cancel() }
        polling?.cancel(); polling = nil
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        model.showsGlobe = needsInputModeSwitchKey
        model.fullAccess = hasFullAccess
    }

    private var polling: Task<Void, Never>?

    /// Fetches the app's state and inserts a finished dictation exactly once.
    /// With `autoStart` (quick dictation), a ready session starts listening at once,
    /// as if the mic had been tapped.
    func refresh(autoStart: Bool = false) {
        model.fullAccess = hasFullAccess
        guard hasFullAccess else { return }
        Task {
            let state = await model.client.state()
            apply(state)
            if autoStart, let state, state.phase == .ready, state.result == nil {
                model.arrivedForDictation = true
                apply(await model.client.send(.start))
            }
        }
    }

    func apply(_ state: KeyboardBridge.State?) {
        model.live = state != nil
        model.state = state ?? KeyboardBridge.State()
        if let result = state?.result, result.id != model.lastInserted {
            model.lastInserted = result.id
            insert(result.text)
            Task { _ = await model.client.send(.consume, query: [URLQueryItem(name: "id", value: result.id.uuidString)]) }
            // Quick dictation: hand back to the keyboard the user came from (Apple's, typically).
            if model.arrivedForDictation, model.quickDictation {
                model.arrivedForDictation = false
                advanceToNextInputMode()
            }
        }
        if model.state.phase == .listening { startPolling() }
    }

    /// While listening, fetch the live voice bands about 20 times a second for the ring.
    private func startPolling() {
        guard polling == nil else { return }
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                let state = await self.model.client.state()
                guard let state, state.phase == .listening else { self.polling = nil; self.apply(state); return }
                self.model.state = state
            }
        }
    }

    private func insert(_ text: String) {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let needsSpace = !(before.isEmpty || before.last?.isWhitespace == true || before.last == "(")
        textDocumentProxy.insertText((needsSpace ? " " : "") + text)
    }

    /// The app being typed in (UIKit's private host bundle id), so OmniFlow can
    /// hand straight back to it after turning dictation on. Nil if unavailable,
    /// and always nil in App Store builds.
    private var hostBundleID: String? {
        #if OMNIFLOW_IOS_PRIVATE_APIS
        let key = "_hostBundleID"
        guard responds(to: NSSelectorFromString(key)) else { return nil }
        return value(forKey: key) as? String
        #else
        return nil
        #endif
    }

    /// Keyboards may not open URLs directly; the system application object in
    /// the responder chain still can.
    func openOmniFlow() {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector), current.isKind(of: NSClassFromString("UIApplication")!) {
                typealias Open = @convention(c) (AnyObject, Selector, URL, NSDictionary, Any?) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: Open.self)
                open(current, selector, model.client.newPairing(host: hostBundleID).url, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
        model.note = "Open the OmniFlow app to turn on keyboard dictation."
    }
}

@MainActor
final class KeyboardModel: ObservableObject {
    @Published var state = KeyboardBridge.State()
    @Published var fullAccess = true
    @Published var showsGlobe = true
    @Published var note: String?
    /// True when the app answered: it's running and holding the microphone for us.
    @Published var live = false
    /// The keyboard is a dictation switcher: it starts listening as soon as it
    /// appears and hands back to the previous keyboard once the text is in.
    let quickDictation = true
    var arrivedForDictation = false
    var lastInserted: UUID?
    let client = KeyboardClient()
    weak var controller: KeyboardViewController?

    var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    func micTapped() {
        note = nil
        guard fullAccess else { return }
        Task {
            guard let state = await client.state(), state.phase != .off else { live = false; controller?.openOmniFlow(); return }
            switch state.phase {
            case .listening: apply(await client.send(.stop))
            case .ready: apply(await client.send(.start))
            case .finishing, .off: break
            }
        }
    }

    func cancel() {
        arrivedForDictation = false
        Task { apply(await client.send(.cancel)) }
    }

    private func apply(_ state: KeyboardBridge.State?) {
        if state == nil { note = "OmniFlow stopped. Tap the mic to turn dictation on again." }
        controller?.apply(state)
    }
}

struct KeyboardView: View {
    static let height: CGFloat = 230
    @ObservedObject var model: KeyboardModel
    @Environment(\.colorScheme) private var scheme

    private var live: Bool { model.live && model.state.phase != .off }
    private var listening: Bool { live && model.state.phase == .listening }

    var body: some View {
        VStack(spacing: 0) {
            status
                .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64, alignment: .bottomLeading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .clipped()
            Spacer(minLength: 0)
            ZStack {
                VoiceRing(listening: listening, color: KeyboardPalette.accent(scheme)) {
                    (model.state.bands, model.state.bands, model.state.level)
                }
                .frame(width: 136, height: 136)
                .opacity(live ? 1 : 0.5)
                micButton
            }
            Spacer(minLength: 0)
            // Only on devices without a system globe key below the keyboard.
            if model.showsGlobe {
                HStack {
                    GlobeKey(controller: model.controller).frame(width: 46, height: 40)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
        .frame(height: Self.height)
        .background {
            // The same voice-reactive aura as the app, kept soft behind the keys.
            ListeningAura(active: listening) { model.state.level }
                .opacity(0.8)
                .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.state.phase)
        .animation(.easeOut(duration: 0.2), value: model.state.liveText)
    }

    private var micButton: some View {
        Button(action: model.micTapped) {
            ZStack {
                Circle().fill(listening ? Color.red : KeyboardPalette.accent(scheme))
                    .shadow(color: (listening ? Color.red : KeyboardPalette.accent(scheme)).opacity(0.3), radius: 10, y: 4)
                RoundedRectangle(cornerRadius: listening ? 5 : 12, style: .continuous).fill(.white)
                    .frame(width: listening ? 20 : 0, height: listening ? 20 : 0)
                WaveformGlyph(size: 32).foregroundStyle(.white)
                    .opacity(listening ? 0 : 1).scaleEffect(listening ? 0.4 : 1)
                if model.state.phase == .finishing { ProgressView().tint(.white) }
            }
            .frame(width: 64, height: 64)
            .contentShape(Circle())
        }
        .buttonStyle(KeyPress())
        .disabled(!model.fullAccess || model.state.phase == .finishing)
        .accessibilityLabel(listening ? "Stop dictation" : "Dictate")
    }

    @ViewBuilder private var status: some View {
        if !model.fullAccess {
            hint("Turn on Allow Full Access for OmniFlow in Settings › General › Keyboard › Keyboards. It lets this keyboard talk to the OmniFlow app on this iPhone; nothing is sent off the device.")
        } else if let note = model.note ?? (live ? nil : model.state.message) {
            hint(note)
        } else if !live {
            hint("Tap the mic to turn on dictation in OmniFlow, then come back here.")
        } else {
            switch model.state.phase {
            case .listening:
                HStack(alignment: .bottom, spacing: 10) {
                    if model.state.liveText.isEmpty {
                        Text("Listening…").font(.system(size: 19, design: .serif)).foregroundStyle(.secondary)
                            .phaseAnimator([0.45, 1.0]) { text, value in text.opacity(value) } animation: { _ in .easeInOut(duration: 1.1) }
                    } else {
                        // The same word-by-word arrival as the app, showing the latest lines.
                        LiveTranscript(text: model.state.liveText, font: .system(size: 19, design: .serif))
                            .lineLimit(2).truncationMode(.head)
                    }
                }
            case .finishing: hint("Finishing…")
            default: hint(model.state.message ?? "Tap the mic and speak.")
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The OmniFlow accent for the keyboard.
enum KeyboardPalette {
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.44, green: 0.85, blue: 0.72) : Color(red: 0.12, green: 0.48, blue: 0.44)
    }
}

struct KeyPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The system's next-keyboard key, which also shows the keyboard list on long press.
private struct GlobeKey: UIViewRepresentable {
    weak var controller: UIInputViewController?

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)), for: .normal)
        button.tintColor = .label
        button.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.16) : UIColor(white: 0, alpha: 0.12) }
        button.layer.cornerRadius = 9
        button.layer.cornerCurve = .continuous
        if let controller {
            button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}

/// Talks to the OmniFlow app's loopback endpoint with the current session's pairing.
@MainActor
final class KeyboardClient {
    /// Kept in the keyboard's own container so a relaunched keyboard can rejoin the session.
    private static let pairingKey = "omniflow.keyboard.pairing"
    private(set) var pairing: KeyboardBridge.Pairing?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.pairingKey),
           let saved = try? JSONDecoder().decode(KeyboardBridge.Pairing.self, from: data), saved.isValid {
            pairing = saved
        }
    }

    /// A fresh token and port for the next session; the previous one is discarded.
    func newPairing(host: String? = nil) -> KeyboardBridge.Pairing {
        let fresh = KeyboardBridge.Pairing.make(host: host)
        pairing = fresh
        UserDefaults.standard.set(try? JSONEncoder().encode(fresh), forKey: Self.pairingKey)
        return fresh
    }

    /// Nil when the app isn't running a keyboard session (or isn't paired with this keyboard).
    func state() async -> KeyboardBridge.State? { await request(.state, method: "GET") }

    func send(_ command: KeyboardBridge.Command, query: [URLQueryItem] = []) async -> KeyboardBridge.State? {
        await request(command, method: "POST", query: query)
    }

    private func request(_ command: KeyboardBridge.Command, method: String, query: [URLQueryItem] = []) async -> KeyboardBridge.State? {
        guard let pairing else { return nil }
        var components = URLComponents()
        components.scheme = "http"; components.host = KeyboardBridge.host; components.port = Int(pairing.port)
        components.path = "/" + command.rawValue
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(pairing.token, forHTTPHeaderField: KeyboardBridge.tokenHeader)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(KeyboardBridge.State.self, from: data)
    }
}
