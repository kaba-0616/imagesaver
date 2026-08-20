import Foundation

/// Identifies one launch of the extension. Logs get pasted together while
/// diagnosing a problem, and without this there is no way to tell a fresh run
/// from a copy of the previous one.
enum RunID {
    private static let counterKey = "runCounter"

    /// Assigned once per process, on first use.
    static let number: Int = {
        let next = UserDefaults.standard.integer(forKey: counterKey) + 1
        UserDefaults.standard.set(next, forKey: counterKey)
        return next
    }()

    static let startedAt = Date()

    /// e.g. "実行 #42  08/20 13:56:12  v1.0 (36)"
    static var label: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm:ss"
        return "実行 #\(number)  \(formatter.string(from: startedAt))  \(AppVersion.short)"
    }
}
