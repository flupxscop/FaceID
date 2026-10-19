import FaceIDCore
import Foundation

/// Accepts XPC connections. Every connection gets the code signing requirement before it is
/// resumed, so no message from an unverified peer ever reaches the service (CLAUDE.md §7.5).
public final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    private let coordinator: AuthenticationCoordinator
    /// nil only for in-process tests, via `init(coordinator:skippingSignatureCheckForTesting:)`.
    private let clientRequirement: String?

    public init(coordinator: AuthenticationCoordinator, clientRequirement: String) {
        self.coordinator = coordinator
        self.clientRequirement = clientRequirement
    }

    /// Test-only: accepts unsigned in-process clients. Not public, so production code cannot reach it.
    init(coordinator: AuthenticationCoordinator, skippingSignatureCheckForTesting: Void) {
        self.coordinator = coordinator
        self.clientRequirement = nil
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let clientRequirement {
            connection.setCodeSigningRequirement(clientRequirement)
        }

        let service = FaceIDService(coordinator: coordinator)
        connection.exportedInterface = FaceIDXPC.makeInterface()
        connection.exportedObject = service
        connection.invalidationHandler = { [weak connection] in
            let pid = connection?.processIdentifier ?? 0
            AgentLog.xpc.notice("connection invalidated (pid \(pid, privacy: .public))")
            service.connectionClosed()
        }
        connection.interruptionHandler = {
            service.connectionClosed()
        }
        connection.resume()
        AgentLog.xpc.notice("accepted connection from pid \(connection.processIdentifier, privacy: .public)")
        return true
    }
}
