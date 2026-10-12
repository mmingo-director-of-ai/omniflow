import SwiftUI
import UIKit

@main
struct OmniFlowiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(OmniFlowAppDelegate.self) private var appDelegate
    @StateObject private var flow: IOSFlowModel
    @StateObject private var keyboard: KeyboardSessionController
    @StateObject private var assistant: IOSAssistantModel

    init() {
        #if DEBUG
        let engine: DictationEngine = DemoDictationEngine.isEnabled ? DemoDictationEngine() : IOSDictationEngine()
        #else
        let engine: DictationEngine = IOSDictationEngine()
        #endif
        let flow = IOSFlowModel(engine: engine)
        _flow = StateObject(wrappedValue: flow)
        _keyboard = StateObject(wrappedValue: KeyboardSessionController(flow: flow))
        _assistant = StateObject(wrappedValue: IOSAssistantModel(flow: flow))
        Theme.applyAppearance()
    }

    var body: some Scene {
        WindowGroup {
            // The banner sits outside the root view, so the environment goes below it.
            IOSAppLockGate { OmniFlowRootView() }
                .safeAreaInset(edge: .top) { if keyboard.active { KeyboardSessionBanner() } }
                .environmentObject(flow)
                .environmentObject(keyboard)
                .environmentObject(assistant)
                .onAppear { LaunchRouting.install(flow: flow, keyboard: keyboard); OmniFlowSync.shared.start() }
                .onReceive(NotificationCenter.default.publisher(for: OmniFlowSync.changed)) { _ in Task { await flow.reloadHistory() } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await OmniFlowSync.shared.sync() } }
                }
                .tint(Theme.accent)
                // The brand is deep emerald; system controls follow it in dark appearance.
                .preferredColorScheme(.dark)
                .onAppear { PairingInbox.shared.deliver = { keyboard.requestBegin($0, sourceApplication: $1) } }
                .alert("Start keyboard dictation?", isPresented: Binding(
                    get: { keyboard.pendingPairing != nil }, set: { if !$0 { keyboard.denyPending() } })) {
                    Button("Allow") { keyboard.allowPending() }
                    Button("Don't Allow", role: .cancel) { keyboard.denyPending() }
                } message: {
                    Text("Something other than the OmniFlow keyboard asked to start keyboard dictation. Allow it only if you just tapped the mic on the OmniFlow keyboard.")
                }
        }
    }
}

/// Shown while the keyboard holds the microphone: how to get back, and how to stop.
struct KeyboardSessionBanner: View {
    @EnvironmentObject private var keyboard: KeyboardSessionController

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if keyboard.listening { WaveformGlyph(size: 24) { keyboard.level } }
                else { Image(systemName: "keyboard").font(.title3) }
            }
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(keyboard.listening ? "Listening for the keyboard" : "Keyboard dictation is on").font(.subheadline.weight(.semibold))
                Group {
                    if let expires = keyboard.expires, !keyboard.listening {
                        Text("Go back with ◀ at the top left. Turns off \(expires, style: .relative).")
                    } else {
                        Text("Go back with ◀ at the top left and use the mic on the OmniFlow keyboard.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Turn off") { keyboard.end() }.buttonStyle(.bordered)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal)
    }
}

/// Pairing URLs arrive through the scene delegate, which (unlike onOpenURL)
/// sees which app opened them. Held until the UI is ready on a cold launch.
@MainActor
final class PairingInbox {
    static let shared = PairingInbox()
    private var waiting: (KeyboardBridge.Pairing, String?)?
    var deliver: ((KeyboardBridge.Pairing, String?) -> Void)? {
        didSet { if let waiting, let deliver { self.waiting = nil; deliver(waiting.0, waiting.1) } }
    }

    func receive(_ contexts: Set<UIOpenURLContext>) {
        for context in contexts {
            // An EPUB shared or opened with OmniFlow: add it to the Reader's library.
            if context.url.isFileURL, context.url.pathExtension.lowercased() == "epub" {
                IOSReaderLibrary.shared.importFiles([context.url])
                continue
            }
            guard let pairing = KeyboardBridge.Pairing(url: context.url) else { continue }
            if let deliver { deliver(pairing, context.options.sourceApplication) }
            else { waiting = (pairing, context.options.sourceApplication) }
        }
    }
}

final class OmniFlowAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = OmniFlowSceneDelegate.self
        return configuration
    }
}

final class OmniFlowSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        PairingInbox.shared.receive(options.urlContexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        PairingInbox.shared.receive(URLContexts)
    }
}

/// Lets code outside the views (launch requests) choose the visible section.
@MainActor
final class AppNavigation: ObservableObject {
    static let shared = AppNavigation()
    @Published var requested: OmniFlowSection?
    /// On iPhone, Translate isn't a tab: a request opens it as a sheet over Dictation.
    @Published var translatePushed = false
    func open(_ section: OmniFlowSection) { requested = section }
}

/// Widgets, Control Center, the Action button and Shortcuts, routed once for
/// the whole app (the first scene to appear installs it; later scenes reuse it).
@MainActor
enum LaunchRouting {
    private static var installed = false

    static func install(flow: IOSFlowModel, keyboard: KeyboardSessionController) {
        guard !installed else { return }
        installed = true
        OmniFlowLaunchRouter.shared.handle = { action in
            switch action {
            case .dictate:
                AppNavigation.shared.open(.dictate)
                if !flow.isDictating { flow.discardReview(); flow.startRecording() }
            case .translate:
                // With a target language set, dictate and translate; otherwise open Translate to pick one.
                if flow.translationTargetID.isEmpty { AppNavigation.shared.open(.translate) }
                else {
                    AppNavigation.shared.open(.dictate)
                    if !flow.isDictating { flow.discardReview(); flow.startRecording() }
                }
            case .newNote:
                AppNavigation.shared.open(.notes)
                guard !flow.isDictating else { return }
                let id = NotesModel.shared.create()
                NotesModel.shared.requestedOpen = id
                flow.dictateIntoNote { text in NotesModel.shared.append(text, to: id) }
            case .stop:
                if flow.phase == .recording { flow.stopRecording() }
                else if keyboard.listening { keyboard.stopFromIsland() }
            }
        }
        #if DEBUG
        // Screenshots: `-OmniFlowDemoLaunch dictate|translate|newNote` acts like a widget tap.
        if let name = UserDefaults.standard.string(forKey: "OmniFlowDemoLaunch") {
            let action: OmniFlowLaunchAction? = ["dictate": .dictate, "translate": .translate, "newNote": .newNote][name]
            if let action { Task { @MainActor in try? await Task.sleep(for: .seconds(1.5)); OmniFlowLaunchRouter.shared.request(action) } }
        }
        #endif
    }
}
