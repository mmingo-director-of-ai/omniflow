import AppKit
import AuthenticationServices

/// macOS browser step for MCP sign-in: the authentication session is anchored
/// to the frontmost OmniFlow window, and the default-browser option opens the
/// system browser. Both complete through the loopback callback.
@MainActor
final class MacOAuthPresenter: MCPOAuthPresenter {
    func presentationAnchor() -> ASPresentationAnchor? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible)
    }
    func openInBrowser(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
}
