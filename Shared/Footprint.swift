import Foundation
import Darwin

/// How much memory this process is holding, as the system measures it.
///
/// Lives in Shared because both sides want it for different reasons: the
/// extension is killed outright when it goes over, and the app's duplicate
/// scan holds a fingerprint per photo for a whole library.
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
