import Foundation
import Darwin

/// How much memory this process is holding, as the system measures it.
enum Footprint {

    /// `phys_footprint` is the figure jetsam watches, and an app extension is
    /// given far less headroom than an app. Going over is not a crash: the
    /// process is killed outright, which from outside looks like the share
    /// sheet closing by itself.
    static var megabytes: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint) / (1024 * 1024)
    }
}

/// Records how each invocation ended, so the next one can say whether the last
/// one was closed or killed.
///
/// A killed extension writes nothing and shows nothing -- and iOS, after a few
/// of them, stops offering the extension in the share sheet at all. Without a
/// marker written on the way out there is no way to tell that from a profile
/// that simply expired.
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
