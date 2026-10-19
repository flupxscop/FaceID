import FaceIDCore
import Foundation
@testable import FaceIDAgentKit

final class MockSettings: AgentSettingsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool

    init(enabled: Bool = true) {
        self.enabled = enabled
    }

    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }
}

final class MockTemplateStore: TemplateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var template: EnrolledTemplate?
    private var _needsApproval: Bool
    private var _approvalGranted: Bool
    private var _approvals = 0

    /// `needsApproval`: the template exists but reads fail until `approveAccess()` succeeds.
    init(enrolled: Bool, needsApproval: Bool = false, approvalGranted: Bool = true) {
        template = enrolled ? EnrolledTemplate(modelIdentifier: "m", embeddings: [FaceEmbedding([1])]) : nil
        _needsApproval = needsApproval
        _approvalGranted = approvalGranted
    }

    var approvals: Int { lock.withLock { _approvals } }

    func load() throws -> EnrolledTemplate? {
        try lock.withLock {
            if _needsApproval { throw FaceIDError.keychainApprovalNeeded }
            return template
        }
    }
    func save(_ template: EnrolledTemplate) throws { lock.withLock { self.template = template } }
    func delete() throws { lock.withLock { template = nil } }
    func approveAccess() throws {
        try lock.withLock {
            _approvals += 1
            guard _approvalGranted else { throw FaceIDError.keychainApprovalNeeded }
            _needsApproval = false
        }
    }
}

actor MockAuthenticator: FaceAuthenticating {
    private let outcome: AuthOutcome
    private let delay: Duration
    private(set) var calls = 0
    private(set) var cancellations = 0
    private(set) var resets = 0
    var lockedOut = false

    init(outcome: AuthOutcome = .match, delay: Duration = .zero) {
        self.outcome = outcome
        self.delay = delay
    }

    func authenticate() async -> AuthOutcome {
        calls += 1
        do {
            try await Task.sleep(for: delay)
        } catch {
            cancellations += 1
            return .error(.cancelled)
        }
        return outcome
    }

    var isLockedOut: Bool { lockedOut }

    func setLockedOut(_ value: Bool) { lockedOut = value }

    func resetAfterPasswordAuthentication() {
        resets += 1
        lockedOut = false
    }
}

actor MockEnroller: FaceEnrolling {
    private let result: EnrollmentProgress
    private let delay: Duration
    private(set) var calls = 0
    private(set) var progress = EnrollmentProgress.idle

    init(result: EnrollmentProgress = EnrollmentProgress(state: .completed, nextPose: nil, fraction: 1, blinkDetected: true, error: nil),
         delay: Duration = .zero) {
        self.result = result
        self.delay = delay
    }

    func enroll() async -> EnrollmentProgress {
        calls += 1
        progress = EnrollmentProgress(state: .capturing, nextPose: .left, fraction: 0.4, blinkDetected: true, error: nil)
        do {
            try await Task.sleep(for: delay)
        } catch {
            progress = EnrollmentProgress(state: .cancelled, nextPose: nil, fraction: 0, blinkDetected: false, error: .cancelled)
            return progress
        }
        progress = result
        return result
    }
}

func makeCoordinator(
    settings: MockSettings = MockSettings(),
    store: MockTemplateStore = MockTemplateStore(enrolled: true),
    enrolled: Bool? = nil,
    authenticator: MockAuthenticator = MockAuthenticator(),
    enroller: MockEnroller = MockEnroller(),
    cameraGranted: Bool = true
) -> AuthenticationCoordinator {
    AuthenticationCoordinator(
        settings: settings,
        store: enrolled.map { MockTemplateStore(enrolled: $0) } ?? store,
        requestCameraAccess: { cameraGranted },
        makeServices: { FaceServices(authenticator: authenticator, enroller: enroller) }
    )
}

/// Polls an async condition; test-only helper for state that changes on another task.
func eventually(timeout: Duration = .seconds(3), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

// MARK: - XPC

enum XPCCallResult<Value: Sendable>: Sendable {
    case reply(Value)
    case connectionError
    case timedOut
}

/// Resumes a continuation exactly once, whichever of reply / error / timeout comes first.
final class OnceResumer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<XPCCallResult<Value>, Never>?

    init(_ continuation: CheckedContinuation<XPCCallResult<Value>, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: XPCCallResult<Value>) {
        let pending = lock.withLock { () -> CheckedContinuation<XPCCallResult<Value>, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: result)
    }
}

/// In-process listener + client connected through an anonymous endpoint.
final class XPCHarness: @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    let delegate: AgentListenerDelegate
    let connection: NSXPCConnection

    init(delegate: AgentListenerDelegate) {
        self.delegate = delegate
        listener.delegate = delegate
        listener.resume()
        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = FaceIDXPC.makeInterface()
        connection.resume()
    }

    func call<Value: Sendable>(
        timeout: Duration = .seconds(5),
        _ body: @escaping @Sendable (FaceIDServiceProtocol, @escaping @Sendable (Value) -> Void) -> Void
    ) async -> XPCCallResult<Value> {
        await withCheckedContinuation { continuation in
            let once = OnceResumer(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                once.resume(.connectionError)
            }
            guard let service = proxy as? FaceIDServiceProtocol else {
                once.resume(.connectionError)
                return
            }
            body(service) { once.resume(.reply($0)) }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(.timedOut)
            }
        }
    }

    func invalidate() {
        connection.invalidate()
        listener.invalidate()
    }
}
