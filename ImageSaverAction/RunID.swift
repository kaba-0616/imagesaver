import Foundation

/// Identifies one invocation of the extension. Logs get pasted together while
/// diagnosing a problem, and without this there is no way to tell a fresh run
/// from a copy of the previous one.
enum RunID {
    private static let counterKey = "runCounter"

    private(set) static var label = "実行 #-"

    /// Must be called once per share-sheet invocation. The extension's process
    /// is reused across invocations, so anything initialised once per process
    /// stamps every run alike -- same number, same timestamp.
    static func beginRun() {
        let next = UserDefaults.standard.integer(forKey: counterKey) + 1
        UserDefaults.standard.set(next, forKey: counterKey)

        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm:ss"
        label = "実行 #\(next)  \(formatter.string(from: Date()))  \(AppVersion.short)"
    }
}
