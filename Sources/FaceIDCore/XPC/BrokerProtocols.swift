import Foundation

/// The only calls that cross from the lock screen to a user's agent, relayed by FaceIDBroker.
///
/// The authorization plugin's host runs as `_securityagent` and cannot look up services in the
/// user's launchd domain (seen in a VM), so it talks to FaceIDBroker's system-wide service
/// instead. Each agent connects out to the broker and exports only this protocol on that
/// connection — enrollment and deletion stay reachable from the menu bar app alone.
@objc(FaceIDUnlockServiceProtocol) public protocol FaceIDUnlockServiceProtocol {
    /// Runs one face scan. `reply` receives an `AuthResultCode` raw value.
    @objc(authenticateWithRequestID:reply:)
    func authenticate(requestID: String, reply: @escaping @Sendable (Int) -> Void)
    @objc(cancelAuthenticationWithRequestID:)
    func cancelAuthentication(requestID: String)
}

/// Exported by FaceIDBroker to the authorization plugin (`com.example.faceid.broker.auth`).
///
/// Same calls as `FaceIDUnlockServiceProtocol`, but the reply also carries the uid of the agent
/// that answered: the plugin's XPC peer is now the broker (root), so it cannot read the session
/// owner from the connection. The broker takes the uid from the agent's verified connection.
///
/// The Objective-C plugin declares this in `Plugins/FaceIDAuthPlugin/Sources/FaceIDBrokerAuthProtocol.h`.
@objc(FaceIDBrokerAuthProtocol) public protocol FaceIDBrokerAuthProtocol {
    /// `code` is an `AuthResultCode` raw value; `sessionOwner` is 0 unless an agent answered.
    @objc(authenticateWithRequestID:reply:)
    func authenticate(requestID: String, reply: @escaping @Sendable (_ code: Int, _ sessionOwner: UInt32) -> Void)
    @objc(cancelAuthenticationWithRequestID:)
    func cancelAuthentication(requestID: String)
}

/// Exported by FaceIDBroker to agents.
@objc(FaceIDBrokerRegistrationProtocol) public protocol FaceIDBrokerRegistrationProtocol {
    /// Registers the calling agent for its audit session. The agent must export
    /// `FaceIDUnlockServiceProtocol` on the same connection.
    @objc(registerAgentWithReply:)
    func registerAgent(reply: @escaping @Sendable (_ accepted: Bool) -> Void)
}

public enum FaceIDBrokerXPC {
    public static let bundleIdentifier = "com.example.faceid.broker"
    /// System-wide service agents connect to (peers: our agent, pinned certificate).
    public static let agentServiceName = "com.example.faceid.broker.agent"
    /// System-wide service the plugin connects to (peers: Apple's plugin hosts).
    public static let authServiceName = "com.example.faceid.broker.auth"

    public static func unlockInterface() -> NSXPCInterface {
        NSXPCInterface(with: FaceIDUnlockServiceProtocol.self)
    }

    public static func authInterface() -> NSXPCInterface {
        NSXPCInterface(with: FaceIDBrokerAuthProtocol.self)
    }

    public static func registrationInterface() -> NSXPCInterface {
        NSXPCInterface(with: FaceIDBrokerRegistrationProtocol.self)
    }

    /// What the broker requires of agents.
    public static func agentRequirement(certificateSHA1: String) -> String {
        FaceIDXPC.agentRequirement(certificateSHA1: certificateSHA1)
    }
}
