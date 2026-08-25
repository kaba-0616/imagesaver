import Foundation

/// Records how each invocation ended, so the next one can say whether the last
/// one was closed or killed.
///
/// A killed extension writes nothing and shows nothing -- and iOS, after a few
/// of them, stops offering the extension in the share sheet at all. Without a
/// marker written on the way out there is no way to tell that from a profile
/// that simply expired.
///
/// `Footprint` used to live here; it now sits in Shared/ so the app can read it
/// too. Nothing else in this file moved.
enum RunOutcome {
    private static let key = "lastRunOutcome"

    /// What the previous invocation left behind, read before this one
    /// overwrites it.
    private(set) static var previous = "記録なし"

    static func begin() {
        previous = UserDefaults.standard.string(forKey: key) ?? "記録なし"
        note("開始したまま (＝強制終了された)")
    }

    /// Overwrites the marker. Only the last one written survives, which is
    /// what makes the absence of "正常終了" meaningful.
    static func note(_ text: String) {
        UserDefaults.standard.set("\(text) / メモリ \(Footprint.megabytes)MB", forKey: key)
    }
}
