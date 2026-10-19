import FaceIDCore
import Foundation
import ObjectiveC
import Testing
@testable import FaceIDAgentKit
@testable import FaceIDBrokerKit

/// plugin → broker → agent over real (anonymous, in-process) XPC connections.
/// Signature checks are skipped through the test-only initialisers; the real requirements are
/// covered by the configuration tests and by `authListenerRefusesUnsignedPeers` below.
@Suite(.serialized)
struct BrokerEndToEndTests {
    final class Harness: @unchecked Sendable {
        let registry: BrokerRegistry
        let agentListener = NSXPCListener.anonymous()
        let authListener = NSXPCListener.anonymous()
        let agentDelegate: BrokerListenerDelegate
        let authDelegate: BrokerListenerDelegate
        let connector: BrokerConnector
        private(set) var pluginConnection: NSXPCConnection?

        init(authenticator: MockAuthenticator, authRequirement: String? = nil) {
            let registry = BrokerRegistry()
            self.registry = registry
            agentDelegate = BrokerListenerDelegate(role: .agents, registry: registry, skippingSignatureCheckForTesting: ())
            if let authRequirement {
                authDelegate = BrokerListenerDelegate(role: .auth, registry: registry, requirement: authRequirement)
            } else {
                authDelegate = BrokerListenerDelegate(role: .auth, registry: registry, skippingSignatureCheckForTesting: ())
            }
            agentListener.delegate = agentDelegate
            authListener.delegate = authDelegate
            agentListener.resume()
            authListener.resume()

            let endpoint = agentListener.endpoint
            connector = BrokerConnector(
                coordinator: makeCoordinator(authenticator: authenticator),
                brokerRequirement: nil,
                retryInterval: .milliseconds(50)
            ) { NSXPCConnection(listenerEndpoint: endpoint) }
        }

        func connectPlugin() -> NSXPCConnection {
            let connection = NSXPCConnection(listenerEndpoint: authListener.endpoint)
            connection.remoteObjectInterface = FaceIDBrokerXPC.authInterface()
            connection.resume()
            pluginConnection = connection
            return connection
        }

        /// What the plugin would receive.
        func authenticate(requestID: String = "req", timeout: Duration = .seconds(5)) async -> XPCCallResult<[Int]> {
            let connection = pluginConnection ?? connectPlugin()
            return await withCheckedContinuation { continuation in
                let once = OnceResumer<[Int]>(continuation)
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(.connectionError) }
                guard let broker = proxy as? FaceIDBrokerAuthProtocol else {
                    once.resume(.connectionError)
                    return
                }
                broker.authenticate(requestID: requestID) { code, owner in once.resume(.reply([code, Int(owner)])) }
                Task {
                    try? await Task.sleep(for: timeout)
                    once.resume(.timedOut)
                }
            }
        }

        func tearDown() {
            connector.stop()
            pluginConnection?.invalidate()
            agentListener.invalidate()
            authListener.invalidate()
        }
    }

    private func registered(_ harness: Harness) async -> Bool {
        await eventually { harness.connector.isRegistered && harness.registry.count == 1 }
    }

    @Test func agentRegistersWithBroker() async {
        let harness = Harness(authenticator: MockAuthenticator())
        defer { harness.tearDown() }
        harness.connector.start()
        #expect(await registered(harness))
    }

    @Test func matchIsRelayedWithTheAgentsUser() async {
        let harness = Harness(authenticator: MockAuthenticator(outcome: .match))
        defer { harness.tearDown() }
        harness.connector.start()
        #expect(await registered(harness))

        guard case .reply(let reply) = await harness.authenticate() else {
            Issue.record("no reply")
            return
        }
        #expect(reply == [AuthResultCode.match.rawValue, Int(getuid())])
    }

    @Test func noMatchIsRelayedWithoutUser() async {
        let harness = Harness(authenticator: MockAuthenticator(outcome: .noMatch))
        defer { harness.tearDown() }
        harness.connector.start()
        #expect(await registered(harness))

        guard case .reply(let reply) = await harness.authenticate() else {
            Issue.record("no reply")
            return
        }
        #expect(reply == [AuthResultCode.noMatch.rawValue, 0])
    }

    @Test func withoutAgentThePluginGetsAnError() async {
        let harness = Harness(authenticator: MockAuthenticator(outcome: .match))
        defer { harness.tearDown() }
        // Agent never started.
        guard case .reply(let reply) = await harness.authenticate() else {
            Issue.record("no reply")
            return
        }
        #expect(reply == [AuthResultCode.error.rawValue, 0])
    }

    @Test func stoppedAgentIsUnregistered() async {
        let harness = Harness(authenticator: MockAuthenticator(outcome: .match))
        defer { harness.tearDown() }
        harness.connector.start()
        #expect(await registered(harness))
        harness.connector.stop()
        #expect(await eventually { harness.registry.count == 0 })

        guard case .reply(let reply) = await harness.authenticate() else {
            Issue.record("no reply")
            return
        }
        #expect(reply == [AuthResultCode.error.rawValue, 0])
    }

    @Test func agentReRegistersAfterLosingTheBroker() async {
        let harness = Harness(authenticator: MockAuthenticator(outcome: .match))
        defer { harness.tearDown() }
        harness.connector.start()
        #expect(await registered(harness))

        harness.connector.dropConnectionForTesting()
        #expect(await eventually { !harness.connector.isRegistered })
        #expect(await registered(harness))

        guard case .reply(let reply) = await harness.authenticate() else {
            Issue.record("no reply")
            return
        }
        #expect(reply.first == AuthResultCode.match.rawValue)
    }

    @Test func pluginDisconnectStopsTheAgentScan() async {
        let authenticator = MockAuthenticator(delay: .seconds(10))
        let harness = Harness(authenticator: authenticator)
        defer { harness.tearDown() }
        harness.connector.start()
        #expect(await registered(harness))

        let plugin = harness.connectPlugin()
        let proxy = plugin.remoteObjectProxyWithErrorHandler { _ in } as? FaceIDBrokerAuthProtocol
        proxy?.authenticate(requestID: "scan") { _, _ in }
        #expect(await eventually { await authenticator.calls == 1 })

        plugin.invalidate()
        #expect(await eventually { await authenticator.cancellations == 1 })
    }

    @Test func agentExportsOnlyScanAndCancelToTheBroker() throws {
        let unlock = try #require(objc_getProtocol("FaceIDUnlockServiceProtocol"))
        var count: UInt32 = 0
        let methods = protocol_copyMethodDescriptionList(unlock, true, true, &count)
        defer { free(methods) }
        let names = (0..<Int(count)).compactMap { methods?[$0].name.map(NSStringFromSelector) }
        #expect(Set(names) == ["authenticateWithRequestID:reply:", "cancelAuthenticationWithRequestID:"])
        // Enrollment and deletion are not reachable through the broker.
        #expect(!names.contains("startEnrollmentWithReply:"))
        #expect(!names.contains("deleteEnrollmentWithReply:"))
    }

    /// The test runner is not one of Apple's plugin hosts, so the real requirement refuses it.
    @Test func authListenerRefusesUnsignedPeers() async {
        let authenticator = MockAuthenticator(outcome: .match)
        let harness = Harness(authenticator: authenticator, authRequirement: FaceIDXPC.securityAgentRequirement)
        defer { harness.tearDown() }
        harness.connector.start()
        #expect(await registered(harness))

        if case .reply = await harness.authenticate() {
            Issue.record("a peer that fails the requirement got a reply")
        }
        #expect(await authenticator.calls == 0)
    }
}
