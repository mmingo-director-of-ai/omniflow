import Foundation

/// Hands the screen back to the app the user was typing in, after OmniFlow was
/// opened from its keyboard. iOS has no public "go back" call, so this uses the
/// private LSApplicationWorkspace, compiled only into direct builds
/// (OMNIFLOW_IOS_PRIVATE_APIS). Elsewhere, and on failure, it does nothing and
/// the user taps ◀ in the status bar.
@MainActor
enum HostAppReturn {
    @discardableResult
    static func open(_ bundleID: String) -> Bool {
        #if OMNIFLOW_IOS_PRIVATE_APIS
        guard bundleID != Bundle.main.bundleIdentifier,
              let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject
        else { return false }
        let selector = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: selector) else { return false }
        typealias Open = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let open = unsafeBitCast(workspace.method(for: selector), to: Open.self)
        return open(workspace, selector, bundleID as NSString)
        #else
        return false
        #endif
    }
}
