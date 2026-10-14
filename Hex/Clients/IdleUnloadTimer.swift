import Foundation

/// Generation-guarded idle-unload timer shared by the model hosts (ASR batch,
/// streaming engines, language model; audit M4). Cancelling bumps the
/// generation, which also invalidates a timer that already fired and waits for
/// its actor: the owner unloads only when `isCurrent(generation)` still holds.
struct IdleUnloadTimer {
  private(set) var generation: UInt64 = 0
  private var task: Task<Void, Never>?

  mutating func cancel() {
    generation &+= 1
    task?.cancel()
    task = nil
  }

  /// Calls `fire` with the scheduled generation after `delay` (zero: right away).
  mutating func schedule(after delay: Duration, fire: @escaping @Sendable (UInt64) async -> Void) {
    cancel()
    let scheduled = generation
    task = Task {
      if delay > .zero {
        do { try await Task.sleep(for: delay) } catch { return }
      }
      await fire(scheduled)
    }
  }

  func isCurrent(_ scheduled: UInt64) -> Bool { scheduled == generation }

  /// The timer task stops waiting for itself before the owner unloads.
  mutating func detach() { task = nil }
}
