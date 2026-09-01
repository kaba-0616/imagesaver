import Foundation

/// Every string this screen shows that is built from a number, in one place so
/// the wording can be adjusted without hunting through views.
///
/// The formatters are shared instances on purpose: making a DateFormatter or a
/// ByteCountFormatter is expensive enough to show up when a grid of tiles each
/// makes its own. They are not thread safe, so everything here is only ever
/// called from the main thread, where the views are.
enum PhotoScanFormat {

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm:ss"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()

    /// ByteCountFormatter rather than the newer ByteCountFormatStyle: the
    /// latter is iOS 15 too, but writes "1 kB" where every other photo app on
    /// the phone writes "1 KB".
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = true
        return formatter
    }()

    static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }

    static func day(_ date: Date?) -> String {
        guard let date else { return "日付なし" }
        return dayFormatter.string(from: date)
    }

    static func dayTime(_ date: Date?) -> String {
        guard let date else { return "日付なし" }
        return dayTimeFormatter.string(from: date)
    }

    /// nil when the size could not be read, so the caller can leave the label
    /// out rather than print a confident zero.
    static func size(_ bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return byteFormatter.string(fromByteCount: bytes)
    }

    static func pixels(width: Int, height: Int) -> String { "\(width)×\(height)" }

    /// Coarse on purpose. The estimate jitters, and a number that counts down
    /// second by second while jumping around reads as broken.
    static func remaining(_ seconds: TimeInterval) -> String {
        if !seconds.isFinite || seconds < 0 { return "残り時間を見積もっています…" }
        if seconds < 5 { return "まもなく終わります" }
        if seconds < 60 {
            let step = Int((seconds / 10).rounded(.up)) * 10
            return "残り約\(step)秒"
        }
        if seconds < 3600 {
            return "残り約\(Int((seconds / 60).rounded(.up)))分"
        }
        return "残り1時間以上"
    }

    static func milliseconds(since started: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
    }
}
