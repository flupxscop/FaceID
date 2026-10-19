import os

/// Never log images, embeddings or similarity scores in release builds (CLAUDE.md §7.3).
/// Debug-only diagnostics must use `privacy: .private` and be wrapped in `#if DEBUG`.
enum Log {
    static let camera = Logger(subsystem: FaceIDConfig.logSubsystem, category: "camera")
    static let detection = Logger(subsystem: FaceIDConfig.logSubsystem, category: "detection")
    static let recognition = Logger(subsystem: FaceIDConfig.logSubsystem, category: "recognition")
    static let storage = Logger(subsystem: FaceIDConfig.logSubsystem, category: "storage")
    static let auth = Logger(subsystem: FaceIDConfig.logSubsystem, category: "auth")
    static let process = Logger(subsystem: FaceIDConfig.logSubsystem, category: "process")
}
