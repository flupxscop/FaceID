import FaceIDCore
import Foundation

/// Keeps this agent registered with FaceIDBroker, so the lock screen can reach it.
///
/// The agent connects *out* to the broker's system-wide service and exports only
/// `FaceIDUnlockServiceProtocol` on that connection. If the broker restarts, the agent reconnects.
/// The broker must be the exact build pinned in the root-owned `pins.plist` (identifier + cdhash);
/// otherwise nothing is exported. Reconnects back off up to `maxRetryInterval`.
public final class BrokerConnector: @unchecked Sendable {
    // Mutable state is guarded by `lock`.
    private let lock = NSLock()
    private let makeConnection: @Sendable () -> NSXPCConnection
    private let brokerRequirement: String?
    private let coordinator: AuthenticationCoordinator
    private let retryInterval: Duration
    private let maxRetryInterval: Duration
    private var nextRetry: Duration
    private var connection: NSXPCConnection?
    private var registered = false
    private var stopped = false

    /// - Parameter brokerRequirement: nil only in tests (unsigned in-process broker).
    init(
        coordinator: AuthenticationCoordinator,
        brokerRequirement: String?,
        retryInterval: Duration = .seconds(2),
        maxRetryInterval: Duration = .seconds(60),
        makeConnection: @escaping @Sendable () -> NSXPCConnection
    ) {
        self.coordinator = coordinator
        self.brokerRequirement = brokerRequirement
        self.retryInterval = retryInterval
        self.maxRetryInterval = max(retryInterval, maxRetryInterval)
        self.nextRetry = retryInterval
        self.makeConnection = makeConnection
    }

    /// Production: the broker's agent service, pinned to the broker build in `pins.plist`.
    /// Returns nil without valid pins (then the broker could not be verified).
    public static func makeDefault(coordinator: AuthenticationCoordinator, pins: InstallPins?) -> BrokerConnector? {
        guard let pins else { return nil }
        return BrokerConnector(
            coordinator: coordinator,
            brokerRequirement: FaceIDBrokerXPC.brokerRequirement(cdhash: pins.brokerCDHash)
        ) {
            // Privileged: the service lives in the system domain (a LaunchDaemon).
            NSXPCConnection(machServiceName: FaceIDBrokerXPC.agentServiceName, options: .privileged)
        }
    }

    public var isRegistered: Bool { lock.withLock { registered } }

    public func start() {
        lock.withLock { stopped = false }
        openConnection()
    }

    public func stop() {
        let current = lock.withLock { () -> NSXPCConnection? in
            stopped = true
            registered = false
            defer { connection = nil }
            return connection
        }
        current?.invalidate()
    }

    private func openConnection() {
        guard !lock.withLock({ stopped }) else { return }

        let connection = makeConnection()
        if let brokerRequirement {
            connection.setCodeSigningRequirement(brokerRequirement)
        }
        let service = FaceIDService(coordinator: coordinator)
        connection.remoteObjectInterface = FaceIDBrokerXPC.registrationInterface()
        // Only scan/cancel are reachable through the broker; NSXPC rejects every other selector.
        connection.exportedInterface = FaceIDBrokerXPC.unlockInterface()
        connection.exportedObject = service
        connection.invalidationHandler = { [weak self] in
            service.connectionClosed()
            self?.connectionLost(connection)
        }
        // The broker restarted: our registration is gone, so start over with a fresh connection.
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }

        lock.withLock {
            self.connection = connection
            registered = false
        }
        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in }
        (proxy as? FaceIDBrokerRegistrationProtocol)?.registerAgent { [weak self] accepted in
            self?.lock.withLock {
                self?.registered = accepted
                if accepted, let self { self.nextRetry = self.retryInterval }
            }
            if accepted {
                AgentLog.xpc.notice("registered with the broker")
            } else {
                AgentLog.xpc.error("the broker refused this agent")
            }
        }
    }

    /// Test-only: drops the current connection, as if the broker had restarted.
    func dropConnectionForTesting() {
        lock.withLock { connection }?.invalidate()
    }

    private func connectionLost(_ lost: NSXPCConnection) {
        let delay = lock.withLock { () -> Duration? in
            guard connection === lost else { return nil }
            connection = nil
            registered = false
            guard !stopped else { return nil }
            // Back off while the broker keeps refusing us; reset after a successful registration.
            let delay = nextRetry
            nextRetry = min(nextRetry * 2, maxRetryInterval)
            return delay
        }
        guard let delay else { return }
        AgentLog.xpc.notice("lost the broker connection; retrying in \(delay.components.seconds, privacy: .public) s")
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.openConnection()
        }
    }
}
