import FaceIDCore
import Foundation

/// Accepts connections on one of the broker's two services. The code signing requirement is set
/// before the connection is resumed, so no message from an unverified peer is ever handled.
public final class BrokerListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    public enum Role: Sendable {
        /// `com.example.faceid.broker.agent`: our agents register here.
        case agents
        /// `com.example.faceid.broker.auth`: the authorization plugin asks for scans here.
        case auth
    }

    private let role: Role
    private let registry: BrokerRegistry
    /// nil only for in-process tests, via `init(role:registry:skippingSignatureCheckForTesting:)`.
    private let requirement: String?

    public init(role: Role, registry: BrokerRegistry, requirement: String) {
        self.role = role
        self.registry = registry
        self.requirement = requirement
    }

    /// Test-only: accepts unsigned in-process peers. Not public, so production code cannot reach it.
    init(role: Role, registry: BrokerRegistry, skippingSignatureCheckForTesting: Void) {
        self.role = role
        self.registry = registry
        self.requirement = nil
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let requirement {
            connection.setCodeSigningRequirement(requirement)
        }
        let session = connection.auditSessionIdentifier
        let pid = connection.processIdentifier

        switch role {
        case .agents:
            let service = BrokerRegistrationService(
                registry: registry,
                session: session,
                userID: connection.effectiveUserIdentifier,
                link: XPCAgentLink(connection: connection)
            )
            connection.exportedInterface = FaceIDBrokerXPC.registrationInterface()
            connection.remoteObjectInterface = FaceIDBrokerXPC.unlockInterface()
            connection.exportedObject = service
            connection.invalidationHandler = { service.connectionClosed() }
            connection.interruptionHandler = { service.connectionClosed() }
        case .auth:
            let service = BrokerAuthService(registry: registry, session: session)
            connection.exportedInterface = FaceIDBrokerXPC.authInterface()
            connection.exportedObject = service
            connection.invalidationHandler = { service.connectionClosed() }
            connection.interruptionHandler = { service.connectionClosed() }
        }

        connection.resume()
        BrokerLog.xpc.notice("accepted \(self.role == .agents ? "agent" : "plugin", privacy: .public) connection: pid \(pid, privacy: .public), audit session \(session, privacy: .public)")
        return true
    }
}
