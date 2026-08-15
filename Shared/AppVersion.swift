import Foundation

enum AppVersion {
    /// e.g. "v1.0 (9)" — the build number is what changes between test installs,
    /// so it is the quickest way to confirm which binary is actually running.
    static var short: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }
}
