import Foundation

/// Code-signing values written by `Scripts/install.sh` to a root-owned file, so the agent and the
/// broker know what to require of each other.
///
/// The broker is ad-hoc signed: inside the lock screen's plugin host certificate trust cannot be
/// evaluated for non-Apple code (seen in a VM: CSSMERR_TP_NOT_TRUSTED), so the broker is verified
/// by its exact code hash everywhere. The agent and the app keep the local certificate; the broker
/// (root) can evaluate it.
///
/// The file is trusted only if it is owned by root and writable by nobody else — the same
/// protection as the binaries themselves. Anything else fails closed.
public struct InstallPins: Sendable, Equatable {
    public static let defaultURL = URL(fileURLWithPath: "/Library/Application Support/FaceID/pins.plist")
    public static let brokerCDHashKey = "BrokerCDHash"
    public static let agentCertificateKey = "AgentCertificateSHA1"

    /// Uppercase hex, 40 digits.
    public var brokerCDHash: String
    /// Uppercase hex, 40 digits.
    public var agentCertificateSHA1: String

    public init?(brokerCDHash: String, agentCertificateSHA1: String) {
        guard let cdhash = Self.hex40(brokerCDHash), let certificate = Self.hex40(agentCertificateSHA1) else { return nil }
        self.brokerCDHash = cdhash
        self.agentCertificateSHA1 = certificate
    }

    /// Reads and validates the pins file. nil when missing, malformed or not root-protected.
    public static func load(from url: URL = defaultURL) -> InstallPins? {
        guard isRootProtected(url), let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> InstallPins? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let cdhash = plist[brokerCDHashKey] as? String,
              let certificate = plist[agentCertificateKey] as? String
        else { return nil }
        return InstallPins(brokerCDHash: cdhash, agentCertificateSHA1: certificate)
    }

    /// Owned by root, not a symlink, and not writable by group or others.
    static func isRootProtected(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        let isRegularFile = (info.st_mode & S_IFMT) == S_IFREG
        let writableByOthers = (info.st_mode & (S_IWGRP | S_IWOTH)) != 0
        return isRegularFile && info.st_uid == 0 && !writableByOthers
    }

    static func hex40(_ value: String) -> String? {
        let upper = value.uppercased()
        let hex = Set("0123456789ABCDEF")
        return upper.count == 40 && upper.allSatisfy(hex.contains) ? upper : nil
    }
}

extension FaceIDBrokerXPC {
    /// What agents require of the broker: its identifier and the exact build (code hash).
    public static func brokerRequirement(cdhash: String) -> String {
        #"identifier "\#(bundleIdentifier)" and cdhash H"\#(cdhash)""#
    }
}
