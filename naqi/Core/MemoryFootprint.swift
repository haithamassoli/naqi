import Foundation
import os

/// Peak-memory instrumentation for the 1.5 GB budget.
///
/// `phys_footprint` is the figure iOS jetsam actually measures. `resident_size`
/// is the usual mistake: it excludes compressed and IOSurface-backed pages, so
/// a pipeline holding pixel buffers reads far lower than the number that gets
/// it killed.
enum MemoryFootprint {

    /// Bytes, or 0 when the query fails.
    static func current() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static var currentMB: Double { Double(current()) / 1_048_576 }

    /// PRD budget: peak RAM must stay under this on iPhone.
    static let budgetBytes: UInt64 = 1_536 * 1_048_576

    /// Logs the footprint at a named point, and warns once past the budget so a
    /// long job leaves evidence in the log before jetsam takes it.
    static func note(_ label: String) {
        let b = current()
        if b > budgetBytes {
            Log.perf.warning("footprint \(label, privacy: .public): \(Double(b) / 1_048_576, format: .fixed(precision: 0)) MB OVER BUDGET")
        } else {
            Log.perf.debug("footprint \(label, privacy: .public): \(Double(b) / 1_048_576, format: .fixed(precision: 0)) MB")
        }
    }
}
