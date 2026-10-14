import FluidAudio
import Foundation

/// FluidAudio's model hub stays offline for the whole app (inference fails
/// closed). Only explicit install actions open it, and always restore the
/// previous value, also on errors (audit M9). Installs are serialised by
/// `TranscriptionClientLive` (`isInstallingModel`); inference and streaming
/// reservations fail with "busy" meanwhile instead of loading.
enum ModelHubNetwork {
  static func whileInstalling<T>(
    read: () -> Bool = { ModelHub.offlineMode },
    write: (Bool) -> Void = { ModelHub.offlineMode = $0 },
    _ body: () async throws -> T
  ) async rethrows -> T {
    let previous = read()
    write(false)
    defer { write(previous) }
    return try await body()
  }
}
