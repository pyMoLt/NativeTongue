import Darwin.Mach
import Foundation

/// Reports the app process footprint, not the full unified-memory cost of Core ML.
enum ProcessMemoryMeter {
	static func currentFootprintBytes() -> UInt64? {
		var info = task_vm_info_data_t()
		var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
		let status = withUnsafeMutablePointer(to: &info) { pointer in
			pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { values in
				task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), values, &count)
			}
		}
		guard status == KERN_SUCCESS else { return nil }
		return info.phys_footprint
	}
}
