import FaceIDCore
import Foundation
import Testing
@testable import FaceIDAgentKit

/// Agent ↔ mock client over a real (anonymous, in-process) XPC connection.
@Suite(.serialized)
struct XPCIntegrationTests {
    private func harness(_ coordinator: AuthenticationCoordinator) -> XPCHarness {
        XPCHarness(delegate: AgentListenerDelegate(coordinator: coordinator, skippingSignatureCheckForTesting: ()))
    }

    private func authenticate(_ harness: XPCHarness, requestID: String = "req-1") async -> XPCCallResult<Int> {
        await harness.call { service, reply in
            service.authenticate(requestID: requestID, reply: reply)
        }
    }

    @Test func matchOverXPC() async {
        let harness = harness(makeCoordinator())
        defer { harness.invalidate() }
        guard case .reply(let code) = await authenticate(harness) else {
            Issue.record("no reply")
            return
        }
        #expect(AuthResultCode(xpcValue: code) == .match)
    }

    @Test func failuresMapToNonUnlockingCodes() async {
        let harness = harness(makeCoordinator(authenticator: MockAuthenticator(outcome: .livenessFailed)))
        defer { harness.invalidate() }
        guard case .reply(let code) = await authenticate(harness) else {
            Issue.record("no reply")
            return
        }
        #expect(AuthResultCode(xpcValue: code) == .livenessFailed)
        #expect(!AuthResultCode(xpcValue: code).allowsUnlock)
    }

    @Test(arguments: ["", String(repeating: "x", count: 129)])
    func invalidRequestIDIsRejected(requestID: String) async {
        let authenticator = MockAuthenticator()
        let harness = harness(makeCoordinator(authenticator: authenticator))
        defer { harness.invalidate() }
        guard case .reply(let code) = await authenticate(harness, requestID: requestID) else {
            Issue.record("no reply")
            return
        }
        #expect(AuthResultCode(xpcValue: code) == .error)
        #expect(await authenticator.calls == 0)
    }

    @Test func statusOverXPC() async {
        let harness = harness(makeCoordinator(settings: MockSettings(enabled: false), enrolled: true))
        defer { harness.invalidate() }
        let result: XPCCallResult<[Bool]> = await harness.call { service, reply in
            service.status { enabled, enrolled, lockedOut, needsApproval in reply([enabled, enrolled, lockedOut, needsApproval]) }
        }
        guard case .reply(let flags) = result else {
            Issue.record("no reply")
            return
        }
        #expect(flags == [false, true, false, false])
    }

    @Test func cancelOverXPC() async {
        let authenticator = MockAuthenticator(delay: .seconds(10))
        let coordinator = makeCoordinator(authenticator: authenticator)
        let harness = harness(coordinator)
        defer { harness.invalidate() }

        async let result = authenticate(harness, requestID: "scan")
        #expect(await eventually { await coordinator.runningRequestCount == 1 })
        let proxy = harness.connection.remoteObjectProxy as? FaceIDServiceProtocol
        proxy?.cancelAuthentication(requestID: "scan")

        guard case .reply(let code) = await result else {
            Issue.record("no reply")
            return
        }
        #expect(AuthResultCode(xpcValue: code) == .error)
        #expect(await authenticator.cancellations == 1)
    }

    @Test func clientDisconnectCancelsScan() async {
        let authenticator = MockAuthenticator(delay: .seconds(10))
        let coordinator = makeCoordinator(authenticator: authenticator)
        let harness = harness(coordinator)

        let proxy = harness.connection.remoteObjectProxy as? FaceIDServiceProtocol
        proxy?.authenticate(requestID: "scan") { _ in }
        #expect(await eventually { await coordinator.runningRequestCount == 1 })

        harness.invalidate()
        #expect(await eventually { await authenticator.cancellations == 1 })
        #expect(await eventually { await coordinator.runningRequestCount == 0 })
    }

    @Test func enrollmentOverXPCReturnsOnlyProgress() async {
        let coordinator = makeCoordinator(enroller: MockEnroller(delay: .seconds(10)))
        let harness = harness(coordinator)
        defer { harness.invalidate() }

        let started: XPCCallResult<Bool> = await harness.call { service, reply in
            service.startEnrollment(reply: reply)
        }
        guard case .reply(true) = started else {
            Issue.record("enrollment did not start")
            return
        }
        #expect(await eventually { await coordinator.enrollmentProgress().state == .capturing })

        let status: XPCCallResult<[String]> = await harness.call { service, reply in
            service.enrollmentStatus { state, pose, fraction, blink in
                reply(["\(state)", pose ?? "-", "\(fraction)", "\(blink)"])
            }
        }
        guard case .reply(let fields) = status else {
            Issue.record("no status reply")
            return
        }
        #expect(fields == ["\(EnrollmentState.capturing.rawValue)", "left", "0.4", "true"])

        (harness.connection.remoteObjectProxy as? FaceIDServiceProtocol)?.cancelEnrollment()
        #expect(await coordinator.waitForEnrollment()?.state == .cancelled)
    }

    @Test func deleteEnrollmentOverXPC() async throws {
        let store = MockTemplateStore(enrolled: true)
        let harness = harness(makeCoordinator(store: store))
        defer { harness.invalidate() }
        let result: XPCCallResult<Bool> = await harness.call { service, reply in
            service.deleteEnrollment(reply: reply)
        }
        guard case .reply(true) = result else {
            Issue.record("delete failed")
            return
        }
        #expect(try store.load() == nil)
    }

    /// The test runner is not SecurityAgent, so the real requirement must refuse it.
    @Test func unsignedClientIsRefusedBySignatureCheck() async {
        let authenticator = MockAuthenticator()
        let delegate = AgentListenerDelegate(
            coordinator: makeCoordinator(authenticator: authenticator),
            clientRequirement: FaceIDXPC.securityAgentRequirement
        )
        let harness = XPCHarness(delegate: delegate)
        defer { harness.invalidate() }

        let result = await authenticate(harness)
        if case .reply = result {
            Issue.record("peer that fails the code signing requirement got a reply")
        }
        #expect(await authenticator.calls == 0)
    }
}
