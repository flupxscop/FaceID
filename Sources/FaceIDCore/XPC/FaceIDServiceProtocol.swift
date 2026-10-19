import Foundation

/// Interface exported by FaceIDAgent over its Mach service.
///
/// Privacy rule: no method may send images, embeddings, templates or similarity scores.
/// Biometric data stays inside the agent process; `PrivacyGuardTests` enforce this.
///
/// Only the menu bar app connects here. The lock screen reaches the agent through FaceIDBroker
/// with the narrower `FaceIDUnlockServiceProtocol`, whose selectors these `@objc(...)` names match.
@objc(FaceIDServiceProtocol) public protocol FaceIDServiceProtocol {
    /// Runs one face scan. `reply` receives an `AuthResultCode` raw value.
    @objc(authenticateWithRequestID:reply:)
    func authenticate(requestID: String, reply: @escaping @Sendable (Int) -> Void)
    /// Aborts a running scan (e.g. the user started typing the password).
    @objc(cancelAuthenticationWithRequestID:)
    func cancelAuthentication(requestID: String)
    func status(
        reply: @escaping @Sendable (_ enabled: Bool, _ enrolled: Bool, _ lockedOut: Bool, _ needsKeychainApproval: Bool) -> Void
    )
    /// Asks TCC for camera access on behalf of the agent process. The menu bar app calls this
    /// while the user is logged in, because no prompt can appear at the lock screen.
    func requestCameraAccess(reply: @escaping @Sendable (_ granted: Bool) -> Void)

    /// Starts capturing a new template inside the agent. The agent itself asks the owner for
    /// their password (system dialog) before saving. `reply(false)` when busy or unavailable.
    func startEnrollment(reply: @escaping @Sendable (_ started: Bool) -> Void)
    /// `state` is an `EnrollmentState` raw value; `nextPose` an `EnrollmentPose` raw value.
    func enrollmentStatus(
        reply: @escaping @Sendable (_ state: Int, _ nextPose: String?, _ fraction: Double, _ blinkDetected: Bool) -> Void
    )
    func cancelEnrollment()
    /// Deletes the template and destroys its encryption key (crypto-shredding).
    func deleteEnrollment(reply: @escaping @Sendable (_ deleted: Bool) -> Void)
    /// After an agent update: shows the system's "allow access" dialog so the owner can let this
    /// build read the stored template again, instead of enrolling again.
    func approveKeychainAccess(reply: @escaping @Sendable (_ approved: Bool) -> Void)
}

public enum AuthResultCode: Int, Sendable {
    case match = 0
    case noMatch = 1
    case livenessFailed = 2
    case timeout = 3
    case error = 4

    /// Any unknown or missing value is an error, so the caller falls back to the password (fail closed).
    public init(xpcValue: Int?) {
        self = xpcValue.flatMap(AuthResultCode.init(rawValue:)) ?? .error
    }

    /// Only an explicit match unlocks.
    public var allowsUnlock: Bool { self == .match }
}

public enum FaceIDXPC {
    public static let machServiceName = "com.example.faceid.agent"

    public static func makeInterface() -> NSXPCInterface {
        NSXPCInterface(with: FaceIDServiceProtocol.self)
    }

    /// Authorization plugins are hosted by Apple processes, so the XPC peer is Apple's host
    /// rather than our bundle. On macOS 27 the plugin runs in SecurityAgentHelper-<arch>
    /// (seen in a VM), an XPC service inside SecurityAgent.bundle; SecurityAgent itself is kept
    /// for older releases. All must be Apple-signed.
    public static let securityAgentRequirement =
        #"anchor apple and (identifier "com.apple.SecurityAgent" or identifier "com.apple.SecurityAgentHelper.arm64" or identifier "com.apple.SecurityAgentHelper.x86_64")"#

    /// Our own apps: the bundle identifier plus the exact signing certificate (SHA-1).
    /// Works with a free, self-signed local certificate — no Apple Developer Program needed.
    public static func pinnedCertificateRequirement(bundleIdentifier: String, certificateSHA1: String) -> String {
        #"identifier "\#(bundleIdentifier)" and certificate leaf = H"\#(certificateSHA1)""#
    }

    /// What our apps require of the agent before talking to it: its identifier plus the same
    /// signing certificate the app itself carries. Stops a look-alike service from harvesting requests.
    public static let agentBundleIdentifier = "com.example.faceid.agent"

    public static func agentRequirement(certificateSHA1: String) -> String {
        pinnedCertificateRequirement(bundleIdentifier: agentBundleIdentifier, certificateSHA1: certificateSHA1)
    }

    /// Matches no code at all: used when there is no certificate to pin (fail closed).
    public static let neverRequirement = "never"

    /// Any of the given requirements may connect. Pass the result to `setCodeSigningRequirement(_:)`.
    public static func combinedRequirement(_ requirements: [String]) -> String {
        requirements.map { "(\($0))" }.joined(separator: " or ")
    }
}

public extension AuthOutcome {
    var resultCode: AuthResultCode {
        switch self {
        case .match: .match
        case .noMatch: .noMatch
        case .livenessFailed: .livenessFailed
        case .timeout: .timeout
        case .error: .error
        }
    }
}
