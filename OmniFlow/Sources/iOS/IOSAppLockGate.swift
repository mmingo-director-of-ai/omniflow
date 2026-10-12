import LocalAuthentication
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// iOS face of OmniFlowAppLock (shared with the Mac). When the lock is on,
/// OmniFlow locks every time it leaves the screen and after the chosen idle
/// time; the app switcher snapshot is covered too. Unlocking uses Face ID
/// with the passcode as fallback. Keyboard dictation keeps working while
/// locked, as dictation does on the Mac.
struct IOSAppLockGate<Content: View>: View {
    @ObservedObject private var lock = OmniFlowAppLock.shared
    @Environment(\.scenePhase) private var scenePhase
    @ViewBuilder var content: () -> Content
    private let idleCheck = Timer.publish(every: 20, on: .main, in: .common).autoconnect()
    /// Face ID's own sheet makes the scene inactive; only a return from the
    /// background (or launch) asks automatically, so a cancel isn't re-prompted.
    @State private var returningFromBackground = true

    var body: some View {
        ZStack {
            content()
                // Watches touches at the window, never as a gesture on the content:
                // a tap gesture over the whole app swallowed sidebar List selection on iPad.
                .background(TouchActivityWatcher { lock.noteActivity() })
                .accessibilityHidden(covered)
            if covered {
                LockScreen(lock: lock, interactive: lock.isLocked && scenePhase == .active)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: covered)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                lock.lock()
                returningFromBackground = true
            case .active:
                lock.noteActivity()
                if lock.isLocked && returningFromBackground { lock.unlockWithPassword() }
                returningFromBackground = false
            default: break
            }
        }
        .onReceive(idleCheck) { now in lock.checkIdle(now: now) }
        .onAppear {
            if lock.isLocked && returningFromBackground { lock.unlockWithPassword() }
            returningFromBackground = false
        }
    }

    /// Locked, or the lock is on and the app is leaving the screen (switcher snapshot).
    private var covered: Bool { lock.isLocked || (lock.enabled && scenePhase != .active) }
}

private struct LockScreen: View {
    @ObservedObject var lock: OmniFlowAppLock
    let interactive: Bool

    var body: some View {
        ZStack {
            Theme.backdrop
            VStack(spacing: 18) {
                RedPandaView(state: .sleeping).frame(width: 110, height: 110).accessibilityHidden(true)
                Text("OmniFlow is locked").font(Theme.heading(26)).foregroundStyle(Theme.ink)
                Text("Your dictations, notes and history are hidden.").font(.subheadline).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                if interactive {
                    Button {
                        lock.unlockWithPassword()
                    } label: {
                        Label("Unlock with \(lock.biometryName)", systemImage: lock.biometryName == "Face ID" ? "faceid" : "lock.open.fill")
                            .font(.headline)
                            .padding(.horizontal, 22).padding(.vertical, 12)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(Theme.onAccent)
                    }
                    .buttonStyle(PressScale())
                    .disabled(lock.authenticating)
                    if let message = lock.message {
                        Text(message).font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    }
                }
            }
            .padding(32)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Settings rows for the lock.
struct AppLockSettingsSection: View {
    @ObservedObject private var lock = OmniFlowAppLock.shared

    var body: some View {
        Section {
            Toggle("Lock with \(lock.biometryName)", isOn: Binding(get: { lock.enabled }, set: { lock.setEnabled($0) }))
                .disabled(!lock.canAuthenticate)
            Picker("Also lock after", selection: $lock.idleMinutes) {
                Text("Only when I leave the app").tag(0)
                Text("1 minute idle").tag(1)
                Text("5 minutes idle").tag(5)
                Text("15 minutes idle").tag(15)
            }
            .disabled(!lock.enabled)
        } header: {
            Text("Privacy")
        } footer: {
            Text(lock.canAuthenticate
                 ? "OmniFlow locks whenever you leave it, hides itself in the app switcher, and asks for \(lock.biometryName) to show your dictations, notes and history. Keyboard dictation keeps working while locked."
                 : "Set up Face ID or a passcode in Settings to lock OmniFlow.")
        }
    }
}

/// Reports each touch that starts anywhere in the window, without taking part
/// in gesture handling: its recognizer fails at once, cancels nothing and
/// delays nothing, so lists, buttons and scroll views behave as if it were absent.
private struct TouchActivityWatcher: UIViewRepresentable {
    var onTouch: () -> Void

    func makeUIView(context: Context) -> WatcherView { WatcherView(onTouch: onTouch) }
    func updateUIView(_ view: WatcherView, context: Context) { view.recognizer.onTouch = onTouch }

    final class WatcherView: UIView {
        let recognizer: Recognizer

        init(onTouch: @escaping () -> Void) {
            recognizer = Recognizer(onTouch: onTouch)
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }
    }

    final class Recognizer: UIGestureRecognizer {
        var onTouch: () -> Void

        init(onTouch: @escaping () -> Void) {
            self.onTouch = onTouch
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            onTouch()
            state = .failed
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}
