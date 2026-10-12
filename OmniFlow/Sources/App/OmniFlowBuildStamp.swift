import Foundation

/// Version, build number and commit from the app's Info.plist (written at build
/// time by scripts/stamp-build.sh), so testers can tell installs apart.
struct OmniFlowBuildStamp {
    let version: String
    let build: String
    let sha: String

    static let current: OmniFlowBuildStamp = {
        let info = Bundle.main.infoDictionary ?? [:]
        return OmniFlowBuildStamp(version: info["CFBundleShortVersionString"] as? String ?? "?",
                                  build: info["CFBundleVersion"] as? String ?? "?",
                                  sha: info["OmniFlowGitSHA"] as? String ?? "dev")
    }()

    /// "0.1.1 · build 262 · 30fcefa"
    var short: String { "\(version) · build \(build) · \(sha)" }
}
