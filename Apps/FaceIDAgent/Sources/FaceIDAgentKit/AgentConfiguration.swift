import FaceIDCore
import Foundation
import os

enum AgentLog {
    static let xpc = Logger(subsystem: FaceIDConfig.logSubsystem, category: "agent.xpc")
    static let lifecycle = Logger(subsystem: FaceIDConfig.logSubsystem, category: "agent")
}

public struct AgentConfiguration: Sendable, Equatable {
    public static let defaultModelURL = URL(fileURLWithPath: "/Library/Application Support/FaceID/Models/FaceEmbedding.mlmodelc")

    /// SHA-1 of the certificate our own app and broker must be signed with — the agent's own.
    /// When nil (ad-hoc build), nothing may connect.
    public var clientCertificateSHA1: String?
    public var appBundleIdentifier: String
    public var modelURL: URL
    /// Refuse to work unless the OS blocks this process's network access (see `NetworkLockdown`).
    public var requireNetworkIsolation: Bool

    public init(
        clientCertificateSHA1: String?,
        appBundleIdentifier: String,
        modelURL: URL = Self.defaultModelURL,
        requireNetworkIsolation: Bool = Self.isReleaseBuild
    ) {
        self.clientCertificateSHA1 = clientCertificateSHA1.flatMap(Self.validCertificateHash)
        self.appBundleIdentifier = appBundleIdentifier
        self.modelURL = modelURL
        self.requireNetworkIsolation = requireNetworkIsolation
    }

    public static var isReleaseBuild: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    /// Code signing requirement for direct connections to the agent: our menu bar app only.
    /// The lock screen reaches the agent through FaceIDBroker instead (see `BrokerConnector`).
    /// Without a certificate to pin nothing may connect (fail closed).
    public var clientRequirement: String {
        guard let clientCertificateSHA1 else { return FaceIDXPC.neverRequirement }
        return FaceIDXPC.pinnedCertificateRequirement(
            bundleIdentifier: appBundleIdentifier,
            certificateSHA1: clientCertificateSHA1
        )
    }

    /// Reads the embedded Info.plist and the agent's own signature; `--model <path>` overrides the model.
    public static func load(
        bundle: Bundle = .main,
        arguments: [String] = CommandLine.arguments,
        signingCertificate: () -> String? = SigningIdentity.ownLeafCertificateSHA1
    ) -> AgentConfiguration {
        var modelURL = defaultModelURL
        if let index = arguments.firstIndex(of: "--model"), arguments.indices.contains(index + 1) {
            modelURL = URL(fileURLWithPath: arguments[index + 1])
        }
        return AgentConfiguration(
            clientCertificateSHA1: signingCertificate(),
            appBundleIdentifier: bundle.object(forInfoDictionaryKey: "FaceIDAppBundleIdentifier") as? String
                ?? "com.example.faceid.app",
            modelURL: modelURL
        )
    }

    /// Exactly 40 hex digits, normalised to uppercase; anything else is ignored.
    static func validCertificateHash(_ value: String) -> String? {
        let upper = value.uppercased()
        let hex = Set("0123456789ABCDEF")
        return upper.count == 40 && upper.allSatisfy(hex.contains) ? upper : nil
    }
}
