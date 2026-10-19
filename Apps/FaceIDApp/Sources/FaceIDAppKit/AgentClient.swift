import FaceIDCore
import Foundation

public struct AgentStatusSnapshot: Sendable, Equatable {
    public var enabled: Bool
    public var enrolled: Bool
    public var lockedOut: Bool
    /// The agent was updated and must be allowed to read the stored face data again.
    public var needsKeychainApproval: Bool

    public init(enabled: Bool, enrolled: Bool, lockedOut: Bool, needsKeychainApproval: Bool = false) {
        self.enabled = enabled
        self.enrolled = enrolled
        self.lockedOut = lockedOut
        self.needsKeychainApproval = needsKeychainApproval
    }
}

/// Everything the app ever learns about an enrollment: no images, no embeddings.
public struct EnrollmentSnapshot: Sendable, Equatable {
    public var state: EnrollmentState
    public var nextPose: EnrollmentPose?
    public var fraction: Double
    public var blinkDetected: Bool

    public init(state: EnrollmentState, nextPose: EnrollmentPose?, fraction: Double, blinkDetected: Bool) {
        self.state = state
        self.nextPose = nextPose
        self.fraction = fraction
        self.blinkDetected = blinkDetected
    }

    public var isRunning: Bool { state == .capturing || state == .verifyingOwner }
}

/// The app's view of FaceIDAgent. Every call throws `FaceIDError.xpcConnectionFailed`
/// when the agent is unreachable, fails its signature check, or does not answer in time.
public protocol AgentClient: Sendable {
    func status() async throws -> AgentStatusSnapshot
    func requestCameraAccess() async throws -> Bool
    func startEnrollment() async throws -> Bool
    func enrollmentStatus() async throws -> EnrollmentSnapshot
    func cancelEnrollment() async
    func deleteEnrollment() async throws -> Bool
    /// One scan for testing from the menu bar. It never unlocks anything; failures count toward
    /// the lockout like any other scan.
    func testScan() async throws -> AuthResultCode
    /// Shows the system's keychain dialog (owner present). Returns whether access was granted.
    func approveKeychainAccess() async throws -> Bool
}

/// Talks to the agent's Mach service, and only to an agent signed with our own certificate.
public final class XPCAgentClient: AgentClient, @unchecked Sendable {
    // `connection` is guarded by `lock`; NSXPCConnection itself is thread-safe.
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private let agentRequirement: String

    public init(agentRequirement: String) {
        self.agentRequirement = agentRequirement
    }

    /// nil when this app is not certificate-signed: without a certificate to pin, the agent
    /// cannot be verified (and would refuse us anyway).
    public static func makeDefault() -> XPCAgentClient? {
        guard let certificate = SigningIdentity.ownLeafCertificateSHA1() else { return nil }
        return XPCAgentClient(agentRequirement: FaceIDXPC.agentRequirement(certificateSHA1: certificate))
    }

    public func status() async throws -> AgentStatusSnapshot {
        let flags: [Bool] = try await call(timeout: .seconds(3)) { service, reply in
            service.status { enabled, enrolled, lockedOut, needsApproval in
                reply([enabled, enrolled, lockedOut, needsApproval])
            }
        }
        return AgentStatusSnapshot(enabled: flags[0], enrolled: flags[1], lockedOut: flags[2], needsKeychainApproval: flags[3])
    }

    public func requestCameraAccess() async throws -> Bool {
        // The user may take a while to answer the system prompt.
        try await call(timeout: .seconds(120)) { service, reply in
            service.requestCameraAccess(reply: reply)
        }
    }

    public func startEnrollment() async throws -> Bool {
        // First use may load and compile the model.
        try await call(timeout: .seconds(30)) { service, reply in
            service.startEnrollment(reply: reply)
        }
    }

    public func enrollmentStatus() async throws -> EnrollmentSnapshot {
        try await call(timeout: .seconds(3)) { service, reply in
            service.enrollmentStatus { state, pose, fraction, blink in
                reply(EnrollmentSnapshot(
                    state: EnrollmentState(rawValue: state) ?? .failed,
                    nextPose: pose.flatMap(EnrollmentPose.init(rawValue:)),
                    fraction: min(max(fraction, 0), 1),
                    blinkDetected: blink
                ))
            }
        }
    }

    public func cancelEnrollment() async {
        let proxy = currentConnection().remoteObjectProxyWithErrorHandler { _ in }
        (proxy as? FaceIDServiceProtocol)?.cancelEnrollment()
    }

    public func deleteEnrollment() async throws -> Bool {
        try await call(timeout: .seconds(5)) { service, reply in
            service.deleteEnrollment(reply: reply)
        }
    }

    public func approveKeychainAccess() async throws -> Bool {
        // The owner may take a while with the system dialog.
        try await call(timeout: .seconds(120)) { service, reply in
            service.approveKeychainAccess(reply: reply)
        }
    }

    public func testScan() async throws -> AuthResultCode {
        let code: Int = try await call(timeout: .seconds(15)) { service, reply in
            service.authenticate(requestID: "menu-test-" + UUID().uuidString, reply: reply)
        }
        return AuthResultCode(xpcValue: code)
    }

    // MARK: - Connection

    private func currentConnection() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let connection = NSXPCConnection(machServiceName: FaceIDXPC.machServiceName, options: [])
            connection.remoteObjectInterface = FaceIDXPC.makeInterface()
            connection.setCodeSigningRequirement(agentRequirement)
            connection.invalidationHandler = { [weak self] in self?.dropConnection() }
            connection.resume()
            self.connection = connection
            return connection
        }
    }

    private func dropConnection() {
        lock.withLock { connection = nil }
    }

    private func call<Value: Sendable>(
        timeout: Duration,
        _ body: @escaping @Sendable (FaceIDServiceProtocol, @escaping @Sendable (Value) -> Void) -> Void
    ) async throws -> Value {
        let connection = currentConnection()
        let value: Value? = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(nil) }
            guard let service = proxy as? FaceIDServiceProtocol else {
                once.resume(nil)
                return
            }
            body(service) { once.resume($0) }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(nil)
            }
        }
        guard let value else { throw FaceIDError.xpcConnectionFailed }
        return value
    }
}

/// Resumes a continuation exactly once, whichever of reply / error / timeout comes first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value?) {
        let pending = lock.withLock { () -> CheckedContinuation<Value?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
