import Foundation

/// Source of camera frames. Tests must use a mock — never open the real camera in tests.
public protocol CameraProviding: Sendable {
    /// Starts the camera and returns its frames. Ending or cancelling iteration must stop the camera.
    func frames() async throws -> AsyncThrowingStream<CameraFrame, Error>
    /// Stops the camera (camera light must turn off). Must be idempotent.
    func stop() async
}

public protocol FaceAnalyzing: Sendable {
    func analyze(_ frame: CameraFrame) async throws -> FrameAnalysis
}

public protocol EmbeddingProviding: Sendable {
    /// Identifies the model; templates made by a different model are rejected.
    var modelIdentifier: String { get }
    func embedding(for frame: CameraFrame, face: FaceObservation) async throws -> FaceEmbedding
}

public protocol TemplateStoring: Sendable {
    /// Never shows UI: throws `.keychainApprovalNeeded` when the owner has to allow access first.
    func load() throws -> EnrolledTemplate?
    func save(_ template: EnrolledTemplate) throws
    func delete() throws
    /// Asks the owner (system dialog) to let this agent read the stored template again, e.g.
    /// after an update. Only call while the user is at the Mac — never at the lock screen.
    func approveAccess() throws
}

extension TemplateStoring {
    public func approveAccess() throws {
        _ = try load()
    }
}
