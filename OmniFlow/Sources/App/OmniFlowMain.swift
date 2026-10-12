import SwiftUI
import AppKit

@main
struct NotchBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandMenu("Actions") {
                Button("Open OmniFlow") { IslandWorkspace.shared.show() }
                Button("Focus & pointer…") { IslandWorkspace.shared.show(.focus) }
                Button("Monitoring…") { IslandWorkspace.shared.show(.system) }
                Button("Continue reading") { ReaderController.shared.continueReading() }
                Button("Reader…") { IslandWorkspace.shared.show(.reader) }
                Button("Cursor actions…") { CursorActions.shared.engage(at: NSEvent.mouseLocation) }
                Button("Ambient abilities…") { IslandWorkspace.shared.show(.ambient) }
            }
            CommandGroup(replacing: .appVisibility) {
                Button("Hide OmniFlow") { NSApp.hide(nil) }
                    .keyboardShortcut("h", modifiers: .command)
                Button("Hide Others") { NSApp.hideOtherApplications(nil) }
                    .keyboardShortcut("h", modifiers: [.command, .option])
                Button("Show All") { NSApp.unhideAllApplications(nil) }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { IslandWorkspace.shared.show(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
