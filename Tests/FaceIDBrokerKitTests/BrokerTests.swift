@testable import FaceIDCore
import Foundation
import Security
import Testing
@testable import FaceIDBrokerKit

/// Fake agent link: answers with a fixed code, or holds the reply until `release()`.
final class FakeAgentLink: UnlockAgentLink, @unchecked Sendable {
    private let lock = NSLock()
    private let code: Int?
    private var _requests: [String] = []
    private var _cancelled: [String] = []
    private var held: [@Sendable (Int) -> Void] = []

    /// `code == nil`: hold replies (a scan still running).
    init(code: Int?) {
        self.code = code
    }

    var requests: [String] { lock.withLock { _requests } }
    var cancelled: [String] { lock.withLock { _cancelled } }

    func authenticate(requestID: String, reply: @escaping @Sendable (Int) -> Void) {
        lock.withLock { _requests.append(requestID) }
        if let code {
            reply(code)
        } else {
            lock.withLock { held.append(reply) }
        }
    }

    func cancelAuthentication(requestID: String) {
        lock.withLock { _cancelled.append(requestID) }
    }

    func release(_ code: Int) {
        let pending = lock.withLock { () -> [@Sendable (Int) -> Void] in
            defer { held.removeAll() }
            return held
        }
        pending.forEach { $0(code) }
    }
}

final class ReplyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _replies: [(code: Int, owner: UInt32)] = []

    var replies: [(code: Int, owner: UInt32)] { lock.withLock { _replies } }

    var callback: @Sendable (Int, UInt32) -> Void {
        { [self] code, owner in lock.withLock { _replies.append((code, owner)) } }
    }
}

struct BrokerRegistryTests {
    @Test func registersAndFindsAgentBySession() throws {
        let registry = BrokerRegistry()
        let link = FakeAgentLink(code: 0)
        registry.register(session: 100, userID: 501, link: link)
        let agent = try #require(registry.agent(for: 100))
        #expect(agent.userID == 501)
        #expect(agent.link === link)
        #expect(registry.agent(for: 200) == nil)
    }

    @Test func newRegistrationReplacesOld() throws {
        let registry = BrokerRegistry()
        let old = FakeAgentLink(code: 0)
        let new = FakeAgentLink(code: 0)
        let oldToken = registry.register(session: 100, userID: 501, link: old)
        registry.register(session: 100, userID: 501, link: new)
        #expect(try #require(registry.agent(for: 100)).link === new)

        // The old connection closing later must not remove the new agent.
        registry.unregister(session: 100, id: oldToken)
        #expect(try #require(registry.agent(for: 100)).link === new)
        #expect(registry.count == 1)
    }

    @Test func unregisterRemovesCurrentAgent() {
        let registry = BrokerRegistry()
        let token = registry.register(session: 100, userID: 501, link: FakeAgentLink(code: 0))
        registry.unregister(session: 100, id: token)
        #expect(registry.agent(for: 100) == nil)
        #expect(registry.count == 0)
    }
}

struct BrokerAuthServiceTests {
    private func service(_ registry: BrokerRegistry, session: BrokerRegistry.SessionID = 100) -> BrokerAuthService {
        BrokerAuthService(registry: registry, session: session)
    }

    @Test func noAgentFailsClosed() {
        let recorder = ReplyRecorder()
        service(BrokerRegistry()).authenticate(requestID: "r", reply: recorder.callback)
        #expect(recorder.replies.map(\.code) == [AuthResultCode.error.rawValue])
        #expect(recorder.replies.map(\.owner) == [0])
    }

    @Test func agentOfAnotherSessionIsNotUsed() {
        let registry = BrokerRegistry()
        let other = FakeAgentLink(code: 0)
        registry.register(session: 200, userID: 502, link: other)
        let recorder = ReplyRecorder()
        service(registry, session: 100).authenticate(requestID: "r", reply: recorder.callback)
        #expect(recorder.replies.map(\.code) == [AuthResultCode.error.rawValue])
        #expect(other.requests.isEmpty)
    }

    @Test func matchCarriesTheAgentsUser() {
        let registry = BrokerRegistry()
        registry.register(session: 100, userID: 501, link: FakeAgentLink(code: AuthResultCode.match.rawValue))
        let recorder = ReplyRecorder()
        service(registry).authenticate(requestID: "r", reply: recorder.callback)
        #expect(recorder.replies.map(\.code) == [AuthResultCode.match.rawValue])
        #expect(recorder.replies.map(\.owner) == [501])
    }

    @Test(arguments: [AuthResultCode.noMatch.rawValue, AuthResultCode.livenessFailed.rawValue, AuthResultCode.timeout.rawValue])
    func nonMatchCarriesNoUser(code: Int) {
        let registry = BrokerRegistry()
        registry.register(session: 100, userID: 501, link: FakeAgentLink(code: code))
        let recorder = ReplyRecorder()
        service(registry).authenticate(requestID: "r", reply: recorder.callback)
        #expect(recorder.replies.map(\.code) == [code])
        #expect(recorder.replies.map(\.owner) == [0])
    }

    @Test(arguments: [99, -1])
    func unknownAgentCodesBecomeError(code: Int) {
        let registry = BrokerRegistry()
        registry.register(session: 100, userID: 501, link: FakeAgentLink(code: code))
        let recorder = ReplyRecorder()
        service(registry).authenticate(requestID: "r", reply: recorder.callback)
        #expect(recorder.replies.map(\.code) == [AuthResultCode.error.rawValue])
        #expect(recorder.replies.map(\.owner) == [0])
    }

    @Test(arguments: ["", String(repeating: "x", count: 129)])
    func invalidRequestIDsAreRejected(requestID: String) {
        let registry = BrokerRegistry()
        let link = FakeAgentLink(code: 0)
        registry.register(session: 100, userID: 501, link: link)
        let recorder = ReplyRecorder()
        service(registry).authenticate(requestID: requestID, reply: recorder.callback)
        #expect(recorder.replies.map(\.code) == [AuthResultCode.error.rawValue])
        #expect(link.requests.isEmpty)
    }

    @Test func requestIDsAreNamespacedPerConnection() {
        let registry = BrokerRegistry()
        let link = FakeAgentLink(code: 1)
        registry.register(session: 100, userID: 501, link: link)
        service(registry).authenticate(requestID: "same", reply: { _, _ in })
        service(registry).authenticate(requestID: "same", reply: { _, _ in })
        #expect(link.requests.count == 2)
        #expect(Set(link.requests).count == 2)
        #expect(link.requests.allSatisfy { $0.hasSuffix("/same") })
    }

    @Test func cancelForwardsTheSameKey() {
        let registry = BrokerRegistry()
        let link = FakeAgentLink(code: nil)
        registry.register(session: 100, userID: 501, link: link)
        let auth = service(registry)
        auth.authenticate(requestID: "r", reply: { _, _ in })
        auth.cancelAuthentication(requestID: "r")
        #expect(link.cancelled == link.requests)
    }

    @Test func cancelOfUnknownRequestDoesNothing() {
        let registry = BrokerRegistry()
        let link = FakeAgentLink(code: nil)
        registry.register(session: 100, userID: 501, link: link)
        service(registry).cancelAuthentication(requestID: "never-started")
        #expect(link.cancelled.isEmpty)
    }

    @Test func pluginDisconnectCancelsRunningScans() {
        let registry = BrokerRegistry()
        let link = FakeAgentLink(code: nil)
        registry.register(session: 100, userID: 501, link: link)
        let auth = service(registry)
        auth.authenticate(requestID: "a", reply: { _, _ in })
        auth.authenticate(requestID: "b", reply: { _, _ in })
        #expect(auth.outstandingCount == 2)
        auth.connectionClosed()
        #expect(Set(link.cancelled) == Set(link.requests))
        #expect(auth.outstandingCount == 0)
    }

    @Test func finishedScansAreNotTracked() {
        let registry = BrokerRegistry()
        let link = FakeAgentLink(code: nil)
        registry.register(session: 100, userID: 501, link: link)
        let auth = service(registry)
        let recorder = ReplyRecorder()
        auth.authenticate(requestID: "a", reply: recorder.callback)
        link.release(AuthResultCode.noMatch.rawValue)
        #expect(auth.outstandingCount == 0)
        #expect(recorder.replies.count == 1)
    }
}

struct BrokerRegistrationServiceTests {
    @Test func rootAgentIsRefused() {
        let registry = BrokerRegistry()
        let service = BrokerRegistrationService(registry: registry, session: 100, userID: 0, link: FakeAgentLink(code: 0))
        let accepted = Box<Bool?>(nil)
        service.registerAgent { accepted.value = $0 }
        #expect(accepted.value == false)
        #expect(registry.count == 0)
    }

    @Test func registersAndUnregistersOnClose() {
        let registry = BrokerRegistry()
        let service = BrokerRegistrationService(registry: registry, session: 100, userID: 501, link: FakeAgentLink(code: 0))
        let accepted = Box<Bool?>(nil)
        service.registerAgent { accepted.value = $0 }
        #expect(accepted.value == true)
        #expect(registry.agent(for: 100)?.userID == 501)
        service.connectionClosed()
        #expect(registry.count == 0)
    }

    @Test func closingUnregisteredConnectionIsHarmless() {
        let registry = BrokerRegistry()
        registry.register(session: 100, userID: 501, link: FakeAgentLink(code: 0))
        BrokerRegistrationService(registry: registry, session: 100, userID: 501, link: FakeAgentLink(code: 0)).connectionClosed()
        #expect(registry.count == 1)
    }
}

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        _value = value
    }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

struct BrokerConfigurationTests {
    private let certificate = "0123456789ABCDEF0123456789ABCDEF01234567"

    @Test func withoutPinsNoAgentCanRegister() {
        let config = BrokerConfiguration.load(pins: { nil })
        #expect(config.agentRequirement == FaceIDXPC.neverRequirement)
    }

    @Test func agentsMustCarryThePinnedCertificate() {
        let pins = InstallPins(brokerCDHash: String(repeating: "a", count: 40), agentCertificateSHA1: certificate.lowercased())
        let config = BrokerConfiguration.load(pins: { pins })
        #expect(config.agentRequirement == #"identifier "com.example.faceid.agent" and certificate leaf = H"\#(certificate)""#)
    }

    @Test func onlyApplePluginHostsMayAskForScans() {
        #expect(BrokerConfiguration(agentCertificateSHA1: certificate).authRequirement == FaceIDXPC.securityAgentRequirement)
    }

    @Test func requirementsCompile() {
        let config = BrokerConfiguration(agentCertificateSHA1: certificate)
        for text in [config.agentRequirement, config.authRequirement, FaceIDBrokerXPC.brokerRequirement(cdhash: certificate)] {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, "\(text)")
        }
    }

    @Test func debugBuildsDoNotRequireIsolation() {
        #expect(BrokerConfiguration.isReleaseBuild == false)
    }
}

struct InstallPinsTests {
    private let cdhash = "3748B0E42364963B74C728F74C36F6BE5210BA8C"
    private let certificate = "35EE4768C6F6E28C797FC721A258BD699F9F3D06"

    private func plist(_ values: [String: String]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    @Test func parsesValidPins() throws {
        let pins = try #require(InstallPins.parse(try plist([
            InstallPins.brokerCDHashKey: cdhash.lowercased(),
            InstallPins.agentCertificateKey: certificate,
        ])))
        #expect(pins.brokerCDHash == cdhash)
        #expect(pins.agentCertificateSHA1 == certificate)
    }

    @Test(arguments: [
        ["BrokerCDHash": "short", "AgentCertificateSHA1": "35EE4768C6F6E28C797FC721A258BD699F9F3D06"],
        ["BrokerCDHash": "3748B0E42364963B74C728F74C36F6BE5210BA8C"],
        ["AgentCertificateSHA1": "35EE4768C6F6E28C797FC721A258BD699F9F3D06"],
        ["BrokerCDHash": "3748B0E42364963B74C728F74C36F6BE5210BA8C", "AgentCertificateSHA1": "ZZEE4768C6F6E28C797FC721A258BD699F9F3D06"],
    ])
    func rejectsMalformedPins(values: [String: String]) throws {
        #expect(InstallPins.parse(try plist(values)) == nil)
    }

    @Test func rejectsGarbage() {
        #expect(InstallPins.parse(Data("not a plist".utf8)) == nil)
    }

    /// A pins file the user could write must never be trusted.
    @Test func userOwnedFileIsNotTrusted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pins-\(UUID().uuidString).plist")
        try plist([InstallPins.brokerCDHashKey: cdhash, InstallPins.agentCertificateKey: certificate]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!InstallPins.isRootProtected(url))
        #expect(InstallPins.load(from: url) == nil)
    }

    @Test func missingFileIsNotTrusted() {
        #expect(InstallPins.load(from: URL(fileURLWithPath: "/nonexistent/pins.plist")) == nil)
    }

    @Test func rootOwnedReadOnlyFileIsProtected() {
        // Any root-owned, non-writable system file shows the ownership check passing.
        #expect(InstallPins.isRootProtected(URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")))
    }

    @Test func brokerRequirementPinsTheBuild() {
        #expect(FaceIDBrokerXPC.brokerRequirement(cdhash: cdhash) == #"identifier "com.example.faceid.broker" and cdhash H"\#(cdhash)""#)
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString(FaceIDBrokerXPC.brokerRequirement(cdhash: cdhash) as CFString, [], &requirement) == errSecSuccess)
    }
}
