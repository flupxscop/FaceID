import FaceIDCore
import Foundation
import os

enum BrokerLog {
    static let xpc = Logger(subsystem: FaceIDConfig.logSubsystem, category: "broker")
}

/// One registered agent, as the broker sees it.
public protocol UnlockAgentLink: AnyObject, Sendable {
    /// `reply` must be called exactly once, also when the agent goes away.
    func authenticate(requestID: String, reply: @escaping @Sendable (Int) -> Void)
    func cancelAuthentication(requestID: String)
}

/// Agents by audit session. One per session; a new registration replaces the old one.
/// Thread-safe: XPC callbacks arrive on arbitrary queues.
public final class BrokerRegistry: @unchecked Sendable {
    public typealias SessionID = Int32

    private struct Registration {
        let id: UUID
        let userID: uid_t
        let link: any UnlockAgentLink
    }

    public struct Agent: Sendable {
        public let userID: uid_t
        public let link: any UnlockAgentLink
    }

    private let lock = NSLock()
    private var agents: [SessionID: Registration] = [:]

    public init() {}

    /// Returns a token for `unregister`.
    @discardableResult
    public func register(session: SessionID, userID: uid_t, link: any UnlockAgentLink) -> UUID {
        let id = UUID()
        lock.withLock { agents[session] = Registration(id: id, userID: userID, link: link) }
        return id
    }

    /// Removes the registration only if it is still the one identified by `id`.
    public func unregister(session: SessionID, id: UUID) {
        lock.withLock {
            if agents[session]?.id == id {
                agents[session] = nil
            }
        }
    }

    public func agent(for session: SessionID) -> Agent? {
        lock.withLock { agents[session].map { Agent(userID: $0.userID, link: $0.link) } }
    }

    public var count: Int {
        lock.withLock { agents.count }
    }
}

/// Calls a reply block at most once, whichever of reply / error comes first.
final class ReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: (@Sendable (Int) -> Void)?

    init(_ reply: @escaping @Sendable (Int) -> Void) {
        self.reply = reply
    }

    func callAsFunction(_ code: Int) {
        let pending = lock.withLock { () -> (@Sendable (Int) -> Void)? in
            defer { reply = nil }
            return reply
        }
        pending?(code)
    }
}

/// An agent reached over the connection it opened to the broker.
final class XPCAgentLink: UnlockAgentLink, @unchecked Sendable {
    // NSXPCConnection is thread-safe; the link never mutates it.
    private let connection: NSXPCConnection

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func authenticate(requestID: String, reply: @escaping @Sendable (Int) -> Void) {
        let once = ReplyOnce(reply)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            once(AuthResultCode.error.rawValue)
        }
        guard let agent = proxy as? FaceIDUnlockServiceProtocol else {
            once(AuthResultCode.error.rawValue)
            return
        }
        agent.authenticate(requestID: requestID) { code in once(code) }
    }

    func cancelAuthentication(requestID: String) {
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in }
        (proxy as? FaceIDUnlockServiceProtocol)?.cancelAuthentication(requestID: requestID)
    }
}
