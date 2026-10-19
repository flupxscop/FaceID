import FaceIDCore
import Foundation
import Testing
@testable import FaceIDAgentKit

struct AuthenticationCoordinatorTests {
    @Test func disabledNeverScans() async {
        let authenticator = MockAuthenticator()
        let coordinator = makeCoordinator(settings: MockSettings(enabled: false), authenticator: authenticator)
        #expect(await coordinator.authenticate(requestKey: "a") == .error(.disabled))
        #expect(await authenticator.calls == 0)
    }

    @Test func disablingTakesEffectOnNextRequest() async {
        let settings = MockSettings(enabled: true)
        let coordinator = makeCoordinator(settings: settings)
        #expect(await coordinator.authenticate(requestKey: "a") == .match)
        settings.isEnabled = false
        #expect(await coordinator.authenticate(requestKey: "b") == .error(.disabled))
    }

    @Test func passesThroughOutcome() async {
        let coordinator = makeCoordinator(authenticator: MockAuthenticator(outcome: .noMatch))
        #expect(await coordinator.authenticate(requestKey: "a") == .noMatch)
        #expect(await coordinator.runningRequestCount == 0)
    }

    @Test func modelLoadFailureIsReportedAndRetried() async {
        let attempts = Counter()
        let authenticator = MockAuthenticator()
        let coordinator = AuthenticationCoordinator(
            settings: MockSettings(),
            store: MockTemplateStore(enrolled: true),
            requestCameraAccess: { true },
            makeServices: {
                if attempts.increment() == 1 { throw FaceIDError.modelLoadFailed }
                return FaceServices(authenticator: authenticator, enroller: MockEnroller())
            }
        )
        #expect(await coordinator.authenticate(requestKey: "a") == .error(.modelLoadFailed))
        #expect(await coordinator.authenticate(requestKey: "b") == .match)
        #expect(await coordinator.authenticate(requestKey: "c") == .match)
        #expect(attempts.value == 2)
    }

    @Test func duplicateRequestIsBusy() async {
        let coordinator = makeCoordinator(authenticator: MockAuthenticator(delay: .seconds(10)))
        let first = Task { await coordinator.authenticate(requestKey: "a") }
        #expect(await eventually { await coordinator.runningRequestCount == 1 })
        #expect(await coordinator.authenticate(requestKey: "a") == .error(.busy))
        await coordinator.cancel(requestKey: "a")
        #expect(await first.value == .error(.cancelled))
    }

    @Test func cancelStopsRunningScan() async {
        let authenticator = MockAuthenticator(delay: .seconds(10))
        let coordinator = makeCoordinator(authenticator: authenticator)
        let scan = Task { await coordinator.authenticate(requestKey: "conn/a") }
        #expect(await eventually { await coordinator.runningRequestCount == 1 })
        await coordinator.cancelAll(withPrefix: "conn/")
        #expect(await scan.value == .error(.cancelled))
        #expect(await authenticator.cancellations == 1)
        #expect(await coordinator.runningRequestCount == 0)
    }

    @Test func cancelAllLeavesOtherConnectionsAlone() async {
        let coordinator = makeCoordinator(authenticator: MockAuthenticator(delay: .milliseconds(200)))
        let scan = Task { await coordinator.authenticate(requestKey: "other/a") }
        #expect(await eventually { await coordinator.runningRequestCount == 1 })
        await coordinator.cancelAll(withPrefix: "conn/")
        #expect(await scan.value == .match)
    }

    @Test func statusReportsEnrollmentAndLockout() async {
        let authenticator = MockAuthenticator()
        let coordinator = makeCoordinator(enrolled: false, authenticator: authenticator)
        #expect(await coordinator.status() == AgentStatus(enabled: true, enrolled: false, lockedOut: false))

        await coordinator.preload()
        await authenticator.setLockedOut(true)
        #expect(await coordinator.status().lockedOut)

        await coordinator.resetLockout()
        #expect(await authenticator.resets == 1)
        #expect(await !coordinator.status().lockedOut)
    }

    @Test func cameraAccessIsForwarded() async {
        #expect(await makeCoordinator(cameraGranted: false).cameraAccess() == false)
        #expect(await makeCoordinator(cameraGranted: true).cameraAccess() == true)
    }
}

struct EnrollmentCoordinationTests {
    @Test func enrollmentRunsAndReportsProgressOnly() async {
        let enroller = MockEnroller(delay: .milliseconds(100))
        let coordinator = makeCoordinator(enroller: enroller)
        #expect(await coordinator.startEnrollment())
        #expect(await eventually { await coordinator.enrollmentProgress().state == .capturing })
        #expect(await coordinator.enrollmentProgress().nextPose == .left)
        #expect(await coordinator.waitForEnrollment()?.state == .completed)
        #expect(await !coordinator.isEnrolling)
    }

    @Test func onlyOneEnrollmentAtATime() async {
        let coordinator = makeCoordinator(enroller: MockEnroller(delay: .seconds(10)))
        #expect(await coordinator.startEnrollment())
        #expect(await !coordinator.startEnrollment())
        await coordinator.cancelEnrollment()
        #expect(await coordinator.waitForEnrollment()?.state == .cancelled)
    }

    @Test func scanIsRefusedDuringEnrollment() async {
        let authenticator = MockAuthenticator()
        let coordinator = makeCoordinator(authenticator: authenticator, enroller: MockEnroller(delay: .seconds(10)))
        #expect(await coordinator.startEnrollment())
        #expect(await coordinator.authenticate(requestKey: "a") == .error(.busy))
        #expect(await authenticator.calls == 0)
        await coordinator.cancelEnrollment()
        _ = await coordinator.waitForEnrollment()
    }

    @Test func enrollmentIsRefusedDuringScan() async {
        let coordinator = makeCoordinator(authenticator: MockAuthenticator(delay: .seconds(10)))
        let scan = Task { await coordinator.authenticate(requestKey: "a") }
        #expect(await eventually { await coordinator.runningRequestCount == 1 })
        #expect(await !coordinator.startEnrollment())
        await coordinator.cancel(requestKey: "a")
        _ = await scan.value
    }

    @Test func deleteRemovesTemplate() async throws {
        let store = MockTemplateStore(enrolled: true)
        let coordinator = makeCoordinator(store: store)
        #expect(await coordinator.deleteEnrollment())
        #expect(try store.load() == nil)
        #expect(await !coordinator.status().enrolled)
    }

    @Test func deleteIsRefusedDuringEnrollment() async {
        let coordinator = makeCoordinator(enroller: MockEnroller(delay: .seconds(10)))
        #expect(await coordinator.startEnrollment())
        #expect(await !coordinator.deleteEnrollment())
        await coordinator.cancelEnrollment()
        _ = await coordinator.waitForEnrollment()
    }
}

struct KeychainApprovalTests {
    @Test func statusReportsApprovalNeeded() async {
        let store = MockTemplateStore(enrolled: true, needsApproval: true)
        let coordinator = makeCoordinator(store: store)
        let status = await coordinator.status()
        #expect(status.enrolled)
        #expect(status.needsKeychainApproval)
    }

    @Test func approvalClearsTheFlag() async {
        let store = MockTemplateStore(enrolled: true, needsApproval: true)
        let coordinator = makeCoordinator(store: store)
        #expect(await coordinator.approveKeychainAccess())
        #expect(store.approvals == 1)
        #expect(await !coordinator.status().needsKeychainApproval)
    }

    @Test func deniedApprovalIsReported() async {
        let store = MockTemplateStore(enrolled: true, needsApproval: true, approvalGranted: false)
        let coordinator = makeCoordinator(store: store)
        #expect(await !coordinator.approveKeychainAccess())
        #expect(await coordinator.status().needsKeychainApproval)
    }

    @Test func approvalIsRefusedDuringEnrollment() async {
        let store = MockTemplateStore(enrolled: true, needsApproval: true)
        let coordinator = makeCoordinator(store: store, enroller: MockEnroller(delay: .seconds(10)))
        #expect(await coordinator.startEnrollment())
        #expect(await !coordinator.approveKeychainAccess())
        #expect(store.approvals == 0)
        await coordinator.cancelEnrollment()
        _ = await coordinator.waitForEnrollment()
    }
}

struct ScreenUnlockMonitorTests {
    @Test func waitsForTheWindowServerToCatchUp() async {
        // The notification arrives first; the session reports unlocked a moment later.
        let checks = Counter()
        let authenticator = MockAuthenticator()
        let coordinator = makeCoordinator(authenticator: authenticator)
        await coordinator.preload()
        await authenticator.setLockedOut(true)

        let monitor = ScreenUnlockMonitor(
            coordinator: coordinator,
            sessionState: { checks.increment() < 3 ? .locked : .unlocked },
            recheckInterval: .milliseconds(1)
        )
        #expect(await monitor.handleUnlockSignal())
        #expect(await !coordinator.status().lockedOut)
    }

    @Test func unknownSessionStateFailsClosed() async {
        let authenticator = MockAuthenticator()
        let coordinator = makeCoordinator(authenticator: authenticator)
        await coordinator.preload()
        await authenticator.setLockedOut(true)

        let monitor = ScreenUnlockMonitor(coordinator: coordinator, sessionState: { .unknown }, recheckInterval: .milliseconds(1))
        #expect(await !monitor.handleUnlockSignal())
        #expect(await coordinator.status().lockedOut)
    }

    @Test func resetsLockoutWhenSessionIsUnlocked() async {
        let authenticator = MockAuthenticator()
        let coordinator = makeCoordinator(authenticator: authenticator)
        await coordinator.preload()
        await authenticator.setLockedOut(true)

        let monitor = ScreenUnlockMonitor(coordinator: coordinator, sessionState: { .unlocked }, recheckInterval: .milliseconds(1))
        #expect(await monitor.handleUnlockSignal())
        #expect(await authenticator.resets == 1)
        #expect(await !coordinator.status().lockedOut)
    }

    @Test func spoofedNotificationWhileLockedIsIgnored() async {
        let authenticator = MockAuthenticator()
        let coordinator = makeCoordinator(authenticator: authenticator)
        await coordinator.preload()
        await authenticator.setLockedOut(true)

        let monitor = ScreenUnlockMonitor(coordinator: coordinator, sessionState: { .locked }, recheckInterval: .milliseconds(1))
        #expect(await !monitor.handleUnlockSignal())
        #expect(await authenticator.resets == 0)
        #expect(await coordinator.status().lockedOut)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
