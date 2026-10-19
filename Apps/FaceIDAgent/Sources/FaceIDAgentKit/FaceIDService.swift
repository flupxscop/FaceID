import FaceIDCore
import Foundation

/// Object exported to one XPC connection. Request IDs are namespaced per connection,
/// so one client cannot cancel another client's scan.
final class FaceIDService: NSObject, FaceIDServiceProtocol, FaceIDUnlockServiceProtocol, Sendable {
    static let maxRequestIDLength = 128

    private let coordinator: AuthenticationCoordinator
    private let connectionKey = UUID().uuidString + "/"

    init(coordinator: AuthenticationCoordinator) {
        self.coordinator = coordinator
    }

    func authenticate(requestID: String, reply: @escaping @Sendable (Int) -> Void) {
        guard let key = requestKey(requestID) else {
            reply(AuthResultCode.error.rawValue)
            return
        }
        Task {
            let outcome = await coordinator.authenticate(requestKey: key)
            reply(outcome.resultCode.rawValue)
        }
    }

    func cancelAuthentication(requestID: String) {
        guard let key = requestKey(requestID) else { return }
        Task { await coordinator.cancel(requestKey: key) }
    }

    func status(reply: @escaping @Sendable (Bool, Bool, Bool, Bool) -> Void) {
        Task {
            let status = await coordinator.status()
            reply(status.enabled, status.enrolled, status.lockedOut, status.needsKeychainApproval)
        }
    }

    func approveKeychainAccess(reply: @escaping @Sendable (Bool) -> Void) {
        Task { reply(await coordinator.approveKeychainAccess()) }
    }

    func requestCameraAccess(reply: @escaping @Sendable (Bool) -> Void) {
        Task { reply(await coordinator.cameraAccess()) }
    }

    func startEnrollment(reply: @escaping @Sendable (Bool) -> Void) {
        Task { reply(await coordinator.startEnrollment()) }
    }

    func enrollmentStatus(reply: @escaping @Sendable (Int, String?, Double, Bool) -> Void) {
        Task {
            let progress = await coordinator.enrollmentProgress()
            reply(progress.state.rawValue, progress.nextPose?.rawValue, progress.fraction, progress.blinkDetected)
        }
    }

    func cancelEnrollment() {
        Task { await coordinator.cancelEnrollment() }
    }

    func deleteEnrollment(reply: @escaping @Sendable (Bool) -> Void) {
        Task { reply(await coordinator.deleteEnrollment()) }
    }

    /// The client went away (e.g. SecurityAgent gave up): stop its scans so the camera turns off.
    func connectionClosed() {
        Task { await coordinator.cancelAll(withPrefix: connectionKey) }
    }

    private func requestKey(_ requestID: String) -> String? {
        guard !requestID.isEmpty, requestID.utf8.count <= Self.maxRequestIDLength else { return nil }
        return connectionKey + requestID
    }
}
