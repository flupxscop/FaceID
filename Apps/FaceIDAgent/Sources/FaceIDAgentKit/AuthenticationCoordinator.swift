import FaceIDCore
import Foundation

public protocol FaceAuthenticating: Sendable {
    func authenticate() async -> AuthOutcome
    var isLockedOut: Bool { get async }
    func resetAfterPasswordAuthentication() async
}

extension FaceAuthenticator: FaceAuthenticating {}

public protocol FaceEnrolling: Sendable {
    func enroll() async -> EnrollmentProgress
    var progress: EnrollmentProgress { get async }
}

extension FaceEnroller: FaceEnrolling {}

/// Everything that needs the loaded model.
public struct FaceServices: Sendable {
    public var authenticator: any FaceAuthenticating
    public var enroller: any FaceEnrolling

    public init(authenticator: any FaceAuthenticating, enroller: any FaceEnrolling) {
        self.authenticator = authenticator
        self.enroller = enroller
    }
}

public struct AgentStatus: Sendable, Equatable {
    public var enabled: Bool
    public var enrolled: Bool
    public var lockedOut: Bool
    /// A template exists but this agent build may not read it until the owner allows it.
    public var needsKeychainApproval: Bool = false
}

/// Agent-wide state shared by all XPC connections: the master switch, the lazily loaded
/// services, and the scan or enrollment currently running (so it can be cancelled).
/// Scans and enrollment never run at the same time — they share the camera.
public actor AuthenticationCoordinator {
    public typealias ServicesFactory = @Sendable () async throws -> FaceServices

    private let settings: any AgentSettingsProviding
    private let store: any TemplateStoring
    private let makeServices: ServicesFactory
    private let requestCameraAccess: @Sendable () async -> Bool
    /// When set, the agent refuses to scan or enroll (e.g. network isolation is missing).
    private let unavailableReason: FaceIDError?

    private var services: FaceServices?
    private var running: [String: Task<AuthOutcome, Never>] = [:]
    private var enrollment: Task<EnrollmentProgress, Never>?

    public init(
        settings: any AgentSettingsProviding,
        store: any TemplateStoring,
        requestCameraAccess: @escaping @Sendable () async -> Bool,
        unavailableReason: FaceIDError? = nil,
        makeServices: @escaping ServicesFactory
    ) {
        self.unavailableReason = unavailableReason
        self.settings = settings
        self.store = store
        self.requestCameraAccess = requestCameraAccess
        self.makeServices = makeServices
    }

    // MARK: Authentication

    public func authenticate(requestKey: String) async -> AuthOutcome {
        if let unavailableReason { return .error(unavailableReason) }
        guard settings.isEnabled else { return .error(.disabled) }
        guard running[requestKey] == nil, enrollment == nil else { return .error(.busy) }

        let authenticator: any FaceAuthenticating
        do {
            authenticator = try await loadServices().authenticator
        } catch let error as FaceIDError {
            return .error(error)
        } catch {
            return .error(.modelLoadFailed)
        }

        // Re-check after the await: another request may have started meanwhile.
        guard running[requestKey] == nil, enrollment == nil else { return .error(.busy) }
        let task = Task { await authenticator.authenticate() }
        running[requestKey] = task
        let outcome = await task.value
        running[requestKey] = nil
        return outcome
    }

    public func cancel(requestKey: String) {
        running[requestKey]?.cancel()
    }

    public func cancelAll(withPrefix prefix: String) {
        for (key, task) in running where key.hasPrefix(prefix) {
            task.cancel()
        }
    }

    public var runningRequestCount: Int { running.count }

    // MARK: Enrollment

    /// Returns false when a scan or enrollment is already running or the model is unavailable.
    public func startEnrollment() async -> Bool {
        guard unavailableReason == nil else { return false }
        guard running.isEmpty, enrollment == nil else { return false }
        guard let enroller = try? await loadServices().enroller else { return false }
        guard running.isEmpty, enrollment == nil else { return false }

        enrollment = Task {
            let result = await enroller.enroll()
            self.enrollmentFinished()
            return result
        }
        return true
    }

    /// Waits for the running enrollment, if any (used by tests and shutdown).
    public func waitForEnrollment() async -> EnrollmentProgress? {
        await enrollment?.value
    }

    public func enrollmentProgress() async -> EnrollmentProgress {
        await services?.enroller.progress ?? .idle
    }

    public func cancelEnrollment() {
        enrollment?.cancel()
    }

    public var isEnrolling: Bool { enrollment != nil }

    /// Deletes the template and its key. Refused while enrollment is running.
    public func deleteEnrollment() -> Bool {
        guard enrollment == nil else { return false }
        do {
            try store.delete()
            return true
        } catch {
            return false
        }
    }

    private func enrollmentFinished() {
        enrollment = nil
    }

    // MARK: Status

    public func status() async -> AgentStatus {
        var enrolled = false
        var needsApproval = false
        do {
            enrolled = try store.load() != nil
        } catch FaceIDError.keychainApprovalNeeded {
            enrolled = true
            needsApproval = true
        } catch {
            enrolled = false
        }
        let lockedOut = await services?.authenticator.isLockedOut ?? false
        return AgentStatus(enabled: settings.isEnabled, enrolled: enrolled, lockedOut: lockedOut,
                           needsKeychainApproval: needsApproval)
    }

    /// Owner action from the menu bar app: may show the system's keychain dialog.
    /// Refused while a scan or enrollment runs.
    public func approveKeychainAccess() -> Bool {
        guard running.isEmpty, enrollment == nil else { return false }
        do {
            try store.approveAccess()
            return true
        } catch {
            AgentLog.lifecycle.error("keychain access not approved: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    public func cameraAccess() async -> Bool {
        await requestCameraAccess()
    }

    /// Called by `ScreenUnlockMonitor` once the session is verifiably unlocked.
    public func resetLockout() async {
        await services?.authenticator.resetAfterPasswordAuthentication()
    }

    /// Loads the model ahead of the first unlock. Errors are ignored here and surface per request.
    public func preload() async {
        _ = try? await loadServices()
    }

    /// Loads once; a failed load is retried on the next request.
    private func loadServices() async throws -> FaceServices {
        if let services { return services }
        let loaded = try await makeServices()
        if let services { return services }
        services = loaded
        AgentLog.lifecycle.info("face services ready")
        return loaded
    }
}
