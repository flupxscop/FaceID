import FaceIDCore
import Foundation
import Security
import Testing
@testable import FaceIDAgentKit

/// Keeps the Objective-C plugin, its rule files and the Swift side in agreement.
/// The plugin's runtime behaviour is covered by Scripts/test-plugin.sh (fake engine).
struct PluginContractTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let pluginDir = "Plugins/FaceIDAuthPlugin"

    private static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private static func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private static var source: String {
        get throws { try text("\(pluginDir)/Sources/FaceIDAuthPlugin.m") }
    }

    /// First capture group of `pattern` in the plugin source, or nil.
    private static func capture(_ pattern: String) throws -> String? {
        let source = try source
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source)
        else { return nil }
        return String(source[range])
    }

    private static func stringConstant(_ name: String) throws -> String? {
        try capture(#"static NSString \*const \#(name) = @"([^"]+)";"#)
    }

    private static func integerConstant(_ name: String) throws -> Int? {
        try capture(#"static const [A-Za-z0-9_]+ \#(name) = (-?\d+);"#).flatMap { Int($0) }
    }

    @Test func selectorsMatchTheBrokerProtocol() throws {
        let header = try Self.text("\(Self.pluginDir)/Sources/FaceIDBrokerAuthProtocol.h")
        let authenticate = NSStringFromSelector(#selector(FaceIDBrokerAuthProtocol.authenticate(requestID:reply:)))
        let cancel = NSStringFromSelector(#selector(FaceIDBrokerAuthProtocol.cancelAuthentication(requestID:)))
        #expect(authenticate == "authenticateWithRequestID:reply:")
        #expect(cancel == "cancelAuthenticationWithRequestID:")
        #expect(header.contains("- (void)authenticateWithRequestID:(NSString *)requestID reply:(void (^)(NSInteger code, uint32_t sessionOwner))reply;"))
        #expect(header.contains("- (void)cancelAuthenticationWithRequestID:(NSString *)requestID;"))
        #expect(header.contains("@protocol FaceIDBrokerAuthProtocol"))
        // The agent side of the relay uses the same selectors.
        #expect(NSStringFromSelector(#selector(FaceIDUnlockServiceProtocol.authenticate(requestID:reply:))) == authenticate)
        #expect(NSStringFromSelector(#selector(FaceIDUnlockServiceProtocol.cancelAuthentication(requestID:))) == cancel)
    }

    @Test func constantsMatchTheSwiftSide() throws {
        #expect(try Self.stringConstant("kMachServiceName") == FaceIDBrokerXPC.authServiceName)
        #expect(try Self.stringConstant("kBrokerIdentifier") == FaceIDBrokerXPC.bundleIdentifier)
        let info = try Self.plist("\(Self.pluginDir)/Info.plist")
        #expect(try Self.stringConstant("kPluginBundleIdentifier") == info["CFBundleIdentifier"] as? String)
        #expect(try Self.integerConstant("kAuthResultCodeMatch") == AuthResultCode.match.rawValue)
        let timeout = try #require(try Self.integerConstant("kScanTimeoutSeconds"))
        #expect(timeout > Int(FaceIDConfig.scanTimeout.components.seconds))
        #expect(try Self.source.contains("options:NSXPCConnectionPrivileged"), "the broker lives in the system domain")
    }

    @Test func pinnedBrokerCodeHashMatchesTheScripts() throws {
        let key = try #require(try Self.stringConstant("kPinnedBrokerCDHashKey"))
        #expect(key == "FaceIDBrokerCDHash")
        for script in ["Scripts/build-plugin.sh", "Scripts/install.sh"] {
            #expect(try Self.text(script).contains(key), "\(script) does not use \(key)")
        }
        #expect(try Self.source.contains(#"and cdhash H\"%@\""#))
        // build-app.sh must sign the broker before building the plugin that pins it.
        let build = try Self.text("Scripts/build-app.sh")
        let signBroker = try #require(build.range(of: "--identifier com.example.faceid.broker"))
        let buildPlugin = try #require(build.range(of: #"BROKER_CDHASH="$BROKER_CDHASH" "$ROOT/Scripts/build-plugin.sh""#))
        #expect(signBroker.lowerBound < buildPlugin.lowerBound)
        // The pin is written before the plugin is signed, so the signature seals it.
        let plugin = try Self.text("Scripts/build-plugin.sh")
        let pin = try #require(plugin.range(of: "plutil -insert \(key)"))
        let sign = try #require(plugin.range(of: "codesign --force --sign"))
        #expect(pin.lowerBound < sign.lowerBound)
    }

    @Test func cdhashRequirementCompiles() {
        var requirement: SecRequirement?
        let text = #"identifier "com.example.faceid.broker" and cdhash H"3748B0E42364963B74C728F74C36F6BE5210BA8C""#
        #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
    }

    @Test func pinnedCertificateKeyMatchesTheScripts() throws {
        let key = try #require(try Self.stringConstant("kPinnedCertificateKey"))
        #expect(key == "FaceIDAgentCertificateSHA1")
        for script in ["Scripts/build-plugin.sh", "Scripts/install.sh", "Scripts/test-plugin.sh"] {
            #expect(try Self.text(script).contains(key), "\(script) does not use \(key)")
        }
        // The pin is written before signing, so the signature seals it.
        let build = try Self.text("Scripts/build-plugin.sh")
        let pin = try #require(build.range(of: "plutil -insert \(key)"))
        let sign = try #require(build.range(of: "codesign --force --sign"))
        #expect(pin.lowerBound < sign.lowerBound)
    }

    @Test func pluginFailsClosed() throws {
        let source = try Self.source
        #expect(source.contains("static const AuthorizationResult kNotAcceptedResult = kAuthorizationResultDeny;"))
        // Allow is set in exactly one place: an explicit match reply.
        #expect(source.components(separatedBy: "kAuthorizationResultAllow agentUID:").count == 2)
        #expect(source.contains("if (code == kAuthResultCodeMatch) {"))
        #expect(source.contains("setCodeSigningRequirement:_agentRequirement"))
    }

    @Test func pluginNeverTouchesCameraNetworkOrDisk() throws {
        let source = try Self.source
        for forbidden in ["AVFoundation", "AVCapture", "Vision", "CoreML", "NSURLSession", "socket(", "NSLog(", "printf(",
                          "writeToFile", "writeToURL", "fopen(", "abort(", "exit(", "assert(", "NSAssert", "@throw"] {
            #expect(!source.contains(forbidden), "plugin source contains \(forbidden)")
        }
    }

    @Test func faceRightRunsOnlyOurMechanism() throws {
        let right = try Self.plist("\(Self.pluginDir)/face-right.plist")
        let info = try Self.plist("\(Self.pluginDir)/Info.plist")
        let pluginName = try #require(info["CFBundleExecutable"] as? String)
        #expect(right["class"] as? String == "evaluate-mechanisms")
        // Non-privileged (no ",privileged"): runs in SecurityAgent as the session, not as root.
        #expect(right["mechanisms"] as? [String] == ["\(pluginName):face"])
        #expect(right["shared"] as? Bool == false)
        #expect(try Self.source.contains(#"kFaceMechanismId = "face""#))
    }

    @Test func screensaverRuleIsFaceOrPassword() throws {
        let rule = try Self.plist("\(Self.pluginDir)/screensaver-rule.plist")
        #expect(rule["class"] as? String == "rule")
        #expect(rule["k-of-n"] as? Int == 1)
        let options = try #require(rule["rule"] as? [String])
        #expect(options.count == 2)
        #expect(options.first == "com.example.faceid.face")
        // The password must always remain an option (CLAUDE.md §1), and it comes last.
        #expect(options.last == "authenticate-session-owner-or-admin")
    }

    @Test func scriptsUseTheSameRightName() throws {
        for script in ["Scripts/install.sh", "Scripts/uninstall.sh"] {
            #expect(try Self.text(script).contains(#"readonly FACE_RIGHT="com.example.faceid.face""#), "\(script)")
        }
    }

    @Test func installWritesFaceRightBeforeScreensaverRule() throws {
        let install = try Self.text("Scripts/install.sh")
        let right = try #require(install.range(of: #"security authorizationdb write "$FACE_RIGHT""#))
        let screensaver = try #require(install.range(of: #"security authorizationdb write system.login.screensaver < "$PLUGIN_RULE""#))
        #expect(right.lowerBound < screensaver.lowerBound)
    }

    @Test func uninstallRemovesFaceRightAfterRestoringScreensaver() throws {
        let uninstall = try Self.text("Scripts/uninstall.sh")
        let restore = try #require(uninstall.range(of: #"security authorizationdb write "$rule" < "$original""#))
        let remove = try #require(uninstall.range(of: #"security authorizationdb remove "$FACE_RIGHT""#))
        #expect(restore.lowerBound < remove.lowerBound)
    }
}
