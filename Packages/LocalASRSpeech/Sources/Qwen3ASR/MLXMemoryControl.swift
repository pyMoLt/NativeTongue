import MLX

/// NativeTongue addition (not upstream): process-wide MLX memory controls for
/// the app, which does not link MLX directly.
public enum MLXMemoryControl {
	/// Upper bound for MLX's buffer cache (bytes). The app sets it once at
	/// launch; engines only call `capCacheLimit`.
	public static func setCacheLimit(_ bytes: Int) {
		MLX.Memory.cacheLimit = bytes
	}

	public static var cacheLimit: Int { MLX.Memory.cacheLimit }

	/// Lowers the cache limit to `bytes` if it is higher; never raises it, so
	/// one engine cannot lift the app-wide policy for all others (audit M12).
	public static func capCacheLimit(_ bytes: Int) {
		if MLX.Memory.cacheLimit > bytes { MLX.Memory.cacheLimit = bytes }
	}

	/// Returns cached, unused MLX buffers to the system (call after unloading).
	public static func clearCache() {
		MLX.Memory.clearCache()
	}
}

public extension MLXMemoryControl {
	/// (active, cache) bytes currently held by MLX.
	static func usage() -> (active: Int, cache: Int) {
		let snapshot = MLX.Memory.snapshot()
		return (snapshot.activeMemory, snapshot.cacheMemory)
	}
}
