import Foundation

public enum FaceIDError: Error, Equatable, Sendable {
    case cameraUnavailable
    case cameraPermissionDenied
    case detectionFailed
    case modelLoadFailed
    case embeddingFailed
    case notEnrolled
    case invalidTemplate
    case enrollmentIncomplete
    case enrollmentTimedOut
    case ownerVerificationFailed
    case secureEnclaveUnavailable
    case networkNotIsolated
    case lockedOut
    case disabled
    case invalidRequest
    case busy
    case cancelled
    /// The keychain item exists but this (updated) agent may not read it without the owner's OK.
    case keychainApprovalNeeded
    case storageFailure(Int32)
    case encryptionFailure
    case xpcConnectionFailed
    case internalFailure
}
