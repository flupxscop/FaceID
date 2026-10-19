import FaceIDCore
import Foundation
import Security
import Testing
@testable import FaceIDAgentKit

struct AgentConfigurationTests {
    private let certificate = "0123456789ABCDEF0123456789ABCDEF01234567"

    @Test(arguments: ["", "abc", "0123456789ABCDEF0123456789ABCDEF0123456", "0123456789ABCDEF0123456789ABCDEF012345678",
                      "G123456789ABCDEF0123456789ABCDEF01234567", "01234567 9ABCDEF0123456789ABCDEF01234567"])
    func invalidCertificateHashesAreIgnored(value: String) {
        let config = AgentConfiguration(clientCertificateSHA1: value, appBundleIdentifier: "com.example.faceid.app")
        #expect(config.clientCertificateSHA1 == nil)
        #expect(config.clientRequirement == FaceIDXPC.neverRequirement)
    }

    @Test func adHocAgentAcceptsNobody() {
        let config = AgentConfiguration.load(bundle: .main, arguments: ["agent"], signingCertificate: { nil })
        #expect(config.clientRequirement == FaceIDXPC.neverRequirement)
    }

    /// Only the menu bar app connects directly; the lock screen goes through the broker.
    @Test func pinnedCertificateAllowsOnlyOurApp() {
        let config = AgentConfiguration.load(bundle: .main, arguments: ["agent"], signingCertificate: { certificate.lowercased() })
        #expect(config.clientCertificateSHA1 == certificate)
        #expect(config.clientRequirement == #"identifier "com.example.faceid.app" and certificate leaf = H"\#(certificate)""#)
        #expect(!config.clientRequirement.contains("SecurityAgent"))
    }

    @Test func neverRequirementCompilesAndMatchesNothing() throws {
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString(FaceIDXPC.neverRequirement as CFString, [], &requirement) == errSecSuccess)
        let compiled = try #require(requirement)
        var code: SecStaticCode?
        #expect(SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/System/Library/CoreServices/loginwindow.app") as CFURL, [], &code) == errSecSuccess)
        #expect(SecStaticCodeCheckValidity(try #require(code), [], compiled) != errSecSuccess)
    }

    /// The requirement must accept every Apple process that hosts authorization plugins.
    /// Designated requirements read with `codesign -dr-` on macOS 27.
    @Test(arguments: [
        "/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle",
        "/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/XPCServices/SecurityAgentHelper-arm64.xpc",
        "/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/XPCServices/SecurityAgentHelper-x86_64.xpc",
    ])
    func securityAgentRequirementAcceptsPluginHosts(path: String) throws {
        try #require(FileManager.default.fileExists(atPath: path), "not present on this macOS: \(path)")
        var code: SecStaticCode?
        #expect(SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess)
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString(FaceIDXPC.securityAgentRequirement as CFString, [], &requirement) == errSecSuccess)
        let staticCode = try #require(code)
        let compiled = try #require(requirement)
        #expect(SecStaticCodeCheckValidity(staticCode, [], compiled) == errSecSuccess)
    }

    @Test func securityAgentRequirementRejectsOtherAppleCode() throws {
        var code: SecStaticCode?
        #expect(SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/System/Library/CoreServices/loginwindow.app") as CFURL, [], &code) == errSecSuccess)
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString(FaceIDXPC.securityAgentRequirement as CFString, [], &requirement) == errSecSuccess)
        let staticCode = try #require(code)
        let compiled = try #require(requirement)
        #expect(SecStaticCodeCheckValidity(staticCode, [], compiled) != errSecSuccess)
    }

    @Test func requirementsCompile() throws {
        // A malformed requirement would make setCodeSigningRequirement reject every peer.
        let config = AgentConfiguration(clientCertificateSHA1: certificate, appBundleIdentifier: "com.example.faceid.app")
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString(config.clientRequirement as CFString, [], &requirement) == errSecSuccess)
        #expect(requirement != nil)
    }

    @Test func modelArgumentOverridesDefault() {
        let config = AgentConfiguration.load(bundle: .main, arguments: ["agent", "--model", "/tmp/m.mlmodelc"])
        #expect(config.modelURL.path == "/tmp/m.mlmodelc")
        #expect(AgentConfiguration.load(bundle: .main, arguments: ["agent"]).modelURL == AgentConfiguration.defaultModelURL)
    }

    @Test func debugBuildsDoNotRequireIsolation() {
        // swift test builds in debug; release builds default to requiring the sandbox.
        #expect(AgentConfiguration.isReleaseBuild == false)
        #expect(AgentConfiguration(clientCertificateSHA1: nil, appBundleIdentifier: "x").requireNetworkIsolation == false)
    }
}

struct LockdownTests {
    @Test func testRunnerIsNotNetworkIsolated() {
        // Inside `sandbox-exec -f agent.sb` this returns true; verified via `FaceIDAgent --check-isolation`.
        #expect(NetworkLockdown.isNetworkBlocked() == false)
    }

    @Test func ownSigningCertificateHashIsWellFormedWhenPresent() {
        if let hash = SigningIdentity.ownLeafCertificateSHA1() {
            #expect(AgentConfiguration.validCertificateHash(hash) == hash)
        }
    }

    @Test func unavailableAgentRefusesScansAndEnrollment() async {
        let authenticator = MockAuthenticator()
        let enroller = MockEnroller()
        let coordinator = AuthenticationCoordinator(
            settings: MockSettings(),
            store: MockTemplateStore(enrolled: true),
            requestCameraAccess: { true },
            unavailableReason: .networkNotIsolated,
            makeServices: { FaceServices(authenticator: authenticator, enroller: enroller) }
        )
        #expect(await coordinator.authenticate(requestKey: "a") == .error(.networkNotIsolated))
        #expect(await !coordinator.startEnrollment())
        #expect(await authenticator.calls == 0)
        #expect(await enroller.calls == 0)
    }
}

struct ModelIdentityTests {
    private func makeModelDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("faceid-model-\(UUID().uuidString).mlmodelc")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("weights"), withIntermediateDirectories: true)
        try Data("spec".utf8).write(to: dir.appendingPathComponent("model.mil"))
        try Data("weights".utf8).write(to: dir.appendingPathComponent("weights/weight.bin"))
        return dir
    }

    @Test func stableForSameContent() throws {
        let dir = try makeModelDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try ModelIdentity.compute(for: dir)
        #expect(first.hasPrefix("sha256:"))
        #expect(try ModelIdentity.compute(for: dir) == first)
    }

    @Test func changesWhenWeightsChange() throws {
        let dir = try makeModelDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try ModelIdentity.compute(for: dir)
        try Data("other".utf8).write(to: dir.appendingPathComponent("weights/weight.bin"))
        #expect(try ModelIdentity.compute(for: dir) != before)
    }

    @Test func missingModelThrows() {
        #expect(throws: FaceIDError.modelLoadFailed) {
            try ModelIdentity.compute(for: URL(fileURLWithPath: "/nonexistent/model.mlmodelc"))
        }
    }
}
