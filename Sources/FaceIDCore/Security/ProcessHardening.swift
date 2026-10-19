import Darwin

/// Defence in depth for a process that holds camera frames and embeddings in memory.
/// Debugger attachment is blocked by the hardened runtime (no `get-task-allow` in release).
/// Used by FaceIDAgent and FaceIDBroker.
public enum ProcessHardening {
    public static func apply() {
        // No core dumps: they would write process memory (frames, embeddings) to disk.
        var noCore = rlimit(rlim_cur: 0, rlim_max: 0)
        if setrlimit(RLIMIT_CORE, &noCore) != 0 {
            Log.process.error("could not disable core dumps")
        }
        // Anything we ever create is private to the running user.
        umask(0o077)
    }
}
