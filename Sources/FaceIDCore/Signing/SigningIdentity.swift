import CryptoKit
import Foundation
import Security

/// Reads this process's own code signature.
///
/// Without a paid Apple Developer team there is no Team ID to check, so clients are pinned to
/// the exact certificate the agent itself was signed with (a local self-signed certificate works).
public enum SigningIdentity {
    /// SHA-1 (the hash code-signing requirements use) of the leaf signing certificate,
    /// uppercase hex, or nil when the process is ad-hoc signed or unsigned.
    public static func ownLeafCertificateSHA1() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first
        else { return nil }

        let der = SecCertificateCopyData(leaf) as Data
        return Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }
}
