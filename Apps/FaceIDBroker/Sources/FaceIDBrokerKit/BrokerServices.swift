import FaceIDCore
import Foundation

/// Exported to one plugin connection. Forwards scans to the agent of the *same audit session*
/// as the plugin's host and relays only the result code. Fails closed when there is no agent.
final class BrokerAuthService: NSObject, FaceIDBrokerAuthProtocol, @unchecked Sendable {
    static let maxRequestIDLength = 128

    private let registry: BrokerRegistry
    private let session: BrokerRegistry.SessionID
    private let connectionKey = UUID().uuidString
    private let lock = NSLock()
    /// Forwarded request key → the agent it went to, so it can be cancelled.
    private var outstanding: [String: any UnlockAgentLink] = [:]

    init(registry: BrokerRegistry, session: BrokerRegistry.SessionID) {
        self.registry = registry
        self.session = session
    }

    func authenticate(requestID: String, reply: @escaping @Sendable (Int, UInt32) -> Void) {
        guard let key = forwardedKey(requestID) else {
            reply(AuthResultCode.error.rawValue, 0)
            return
        }
        guard let agent = registry.agent(for: session) else {
            BrokerLog.xpc.notice("no agent registered for audit session \(self.session, privacy: .public)")
            reply(AuthResultCode.error.rawValue, 0)
            return
        }
        lock.withLock { outstanding[key] = agent.link }
        agent.link.authenticate(requestID: key) { [weak self] code in
            self?.lock.withLock { _ = self?.outstanding.removeValue(forKey: key) }
            // Normalise: anything unknown becomes .error, so only an explicit match can unlock.
            let result = AuthResultCode(xpcValue: code)
            reply(result.rawValue, result == .match ? agent.userID : 0)
        }
    }

    func cancelAuthentication(requestID: String) {
        guard let key = forwardedKey(requestID),
              let agent = lock.withLock({ outstanding[key] })
        else { return }
        agent.cancelAuthentication(requestID: key)
    }

    /// The plugin went away: stop its scans so the camera turns off.
    func connectionClosed() {
        let pending = lock.withLock { () -> [String: any UnlockAgentLink] in
            defer { outstanding.removeAll() }
            return outstanding
        }
        for (key, agent) in pending {
            agent.cancelAuthentication(requestID: key)
        }
    }

    var outstandingCount: Int { lock.withLock { outstanding.count } }

    private func forwardedKey(_ requestID: String) -> String? {
        guard !requestID.isEmpty, requestID.utf8.count <= Self.maxRequestIDLength else { return nil }
        return connectionKey + "/" + requestID
    }
}

/// Exported to one agent connection.
final class BrokerRegistrationService: NSObject, FaceIDBrokerRegistrationProtocol, @unchecked Sendable {
    private let registry: BrokerRegistry
    private let session: BrokerRegistry.SessionID
    private let userID: uid_t
    private let link: any UnlockAgentLink
    private let lock = NSLock()
    private var token: UUID?

    init(registry: BrokerRegistry, session: BrokerRegistry.SessionID, userID: uid_t, link: any UnlockAgentLink) {
        self.registry = registry
        self.session = session
        self.userID = userID
        self.link = link
    }

    func registerAgent(reply: @escaping @Sendable (Bool) -> Void) {
        // Agents run as the logged-in user, never as root.
        guard userID != 0 else {
            BrokerLog.xpc.error("refused agent running as root")
            reply(false)
            return
        }
        let id = registry.register(session: session, userID: userID, link: link)
        lock.withLock { token = id }
        BrokerLog.xpc.notice("agent registered for audit session \(self.session, privacy: .public)")
        reply(true)
    }

    func connectionClosed() {
        guard let id = lock.withLock({ token }) else { return }
        registry.unregister(session: session, id: id)
        BrokerLog.xpc.notice("agent left audit session \(self.session, privacy: .public)")
    }
}
