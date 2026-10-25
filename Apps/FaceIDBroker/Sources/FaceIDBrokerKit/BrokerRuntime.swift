import FaceIDCore
import Foundation

public struct BrokerConfiguration: Sendable, Equatable {
    /// SHA-1 of the certificate agents must be signed with, from the root-owned pins file
    /// (the broker itself is ad-hoc signed). When nil no agent can register, so every scan fails closed.
    public var agentCertificateSHA1: String?
    public var requireNetworkIsolation: Bool

    public init(agentCertificateSHA1: String?, requireNetworkIsolation: Bool = BrokerConfiguration.isReleaseBuild) {
        self.agentCertificateSHA1 = agentCertificateSHA1.flatMap(Self.validCertificateHash)
        self.requireNetworkIsolation = requireNetworkIsolation
    }

    public static var isReleaseBuild: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    public static func load(pins: () -> InstallPins? = { InstallPins.load() }) -> BrokerConfiguration {
        BrokerConfiguration(agentCertificateSHA1: pins()?.agentCertificateSHA1)
    }

    /// Who may register as an agent.
    public var agentRequirement: String {
        agentCertificateSHA1.map(FaceIDBrokerXPC.agentRequirement(certificateSHA1:)) ?? FaceIDXPC.neverRequirement
    }

    /// Who may ask for scans: Apple's authorization plugin hosts only.
    public var authRequirement: String { FaceIDXPC.securityAgentRequirement }

    static func validCertificateHash(_ value: String) -> String? {
        let upper = value.uppercased()
        let hex = Set("0123456789ABCDEF")
        return upper.count == 40 && upper.allSatisfy(hex.contains) ? upper : nil
    }
}

/// Production wiring for the LaunchDaemon.
public final class BrokerRuntime {
    private let configuration: BrokerConfiguration
    private let registry = BrokerRegistry()
    private let agentListener: NSXPCListener
    private let authListener: NSXPCListener
    private let agentDelegate: BrokerListenerDelegate
    private let authDelegate: BrokerListenerDelegate
    private let watchdog: PluginWatchdog

    public init(configuration: BrokerConfiguration) {
        self.configuration = configuration
        agentDelegate = BrokerListenerDelegate(role: .agents, registry: registry, requirement: configuration.agentRequirement)
        authDelegate = BrokerListenerDelegate(role: .auth, registry: registry, requirement: configuration.authRequirement)
        agentListener = NSXPCListener(machServiceName: FaceIDBrokerXPC.agentServiceName)
        authListener = NSXPCListener(machServiceName: FaceIDBrokerXPC.authServiceName)
        agentListener.delegate = agentDelegate
        authListener.delegate = authDelegate
        watchdog = PluginWatchdog(
            health: SignedPluginHealth(),
            rule: AuthorizationRuleInspector(),
            restorer: UninstallScriptRestorer()
        )
    }

    /// Starts listening and never returns.
    public func run() -> Never {
        ProcessHardening.apply()
        // Before anything else, and even if the listeners stay off: a broken plugin must not
        // leave the lock screen open.
        watchdog.start()
        if configuration.agentCertificateSHA1 == nil {
            BrokerLog.xpc.error("no valid pins file; no agent can register")
        }
        if NetworkLockdown.isNetworkBlocked() || !configuration.requireNetworkIsolation {
            agentListener.resume()
            authListener.resume()
            BrokerLog.xpc.notice("broker listening")
        } else {
            // Not resuming: the plugin's lookups fail and the lock screen falls back to the password.
            BrokerLog.xpc.error("network is not blocked by the sandbox; broker disabled")
        }
        dispatchMain()
    }
}
