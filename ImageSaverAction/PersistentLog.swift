import Foundation

/// Survives the extension being torn down (or crashing) mid-save, so the
/// previous run's trace can be inspected on the next launch.
enum PersistentLog {
    private static let key = "lastSaveLog"

    static func write(_ entries: [PhotoSaver.LogEntry]) {
        // Stamped with the run it came from, so the previous record is never
        // mistaken for part of the current one.
        let lines = [RunID.label] + entries.map { entry in
            (entry.isError ? "[ERR] " : "") + entry.text
        }
        UserDefaults.standard.set(lines, forKey: key)
    }

    static func read() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
