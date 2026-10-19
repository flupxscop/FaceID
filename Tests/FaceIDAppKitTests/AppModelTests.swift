import FaceIDCore
import Foundation
import Testing
@testable import FaceIDAppKit

final class MockEnabledSetting: EnabledSettingStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [Bool] = []

    var history: [Bool] { lock.withLock { writes } }

    func setEnabled(_ enabled: Bool) {
        lock.withLock { writes.append(enabled) }
    }
}

/// Fake agent. `enabled` mirrors what the real agent would read from the shared setting.
actor MockAgent: AgentClient {
    var reachable = true
    var enrolled: Bool
    var enabled = false
    var lockedOut = false
    var cameraGranted = true
    var startAccepted = true
    var deleteSucceeds = true
    /// Snapshots returned by successive `enrollmentStatus()` calls; the last one repeats.
    var enrollmentScript: [EnrollmentSnapshot] = []
    private(set) var cancelCalls = 0
    private(set) var scanCalls = 0
    var scanResult: AuthResultCode = .match
    var needsApproval = false
    var approvalGranted = true
    private(set) var approveCalls = 0
    private(set) var startCalls = 0

    init(enrolled: Bool = false) {
        self.enrolled = enrolled
    }

    func configure(_ change: @Sendable (isolated MockAgent) -> Void) {
        change(self)
    }

    private func ensureReachable() throws {
        guard reachable else { throw FaceIDError.xpcConnectionFailed }
    }

    func status() async throws -> AgentStatusSnapshot {
        try ensureReachable()
        return AgentStatusSnapshot(enabled: enabled, enrolled: enrolled, lockedOut: lockedOut, needsKeychainApproval: needsApproval)
    }

    func requestCameraAccess() async throws -> Bool {
        try ensureReachable()
        return cameraGranted
    }

    func startEnrollment() async throws -> Bool {
        try ensureReachable()
        startCalls += 1
        return startAccepted
    }

    func enrollmentStatus() async throws -> EnrollmentSnapshot {
        try ensureReachable()
        guard !enrollmentScript.isEmpty else {
            return EnrollmentSnapshot(state: .idle, nextPose: nil, fraction: 0, blinkDetected: false)
        }
        let next = enrollmentScript.count > 1 ? enrollmentScript.removeFirst() : enrollmentScript[0]
        if next.state == .completed { enrolled = true }
        return next
    }

    func cancelEnrollment() async {
        cancelCalls += 1
    }

    func approveKeychainAccess() async throws -> Bool {
        try ensureReachable()
        approveCalls += 1
        if approvalGranted { needsApproval = false }
        return approvalGranted
    }

    func testScan() async throws -> AuthResultCode {
        try ensureReachable()
        scanCalls += 1
        return scanResult
    }

    func deleteEnrollment() async throws -> Bool {
        try ensureReachable()
        if deleteSucceeds { enrolled = false }
        return deleteSucceeds
    }
}

@MainActor
struct AppModelTests {
    private func makeModel(_ agent: MockAgent?, settings: MockEnabledSetting = MockEnabledSetting()) -> AppModel {
        AppModel(client: agent, settings: settings, pollInterval: .milliseconds(5))
    }

    private func capturing(_ pose: EnrollmentPose, _ fraction: Double, blink: Bool = false) -> EnrollmentSnapshot {
        EnrollmentSnapshot(state: .capturing, nextPose: pose, fraction: fraction, blinkDetected: blink)
    }

    private func finished(_ state: EnrollmentState) -> EnrollmentSnapshot {
        EnrollmentSnapshot(state: state, nextPose: nil, fraction: state == .completed ? 1 : 0, blinkDetected: false)
    }

    @Test func unsignedAppNeverConnects() async {
        let model = makeModel(nil)
        await model.refresh()
        #expect(model.connection == .unsigned)
        #expect(!model.canEnable)
    }

    @Test func refreshReflectsAgentStatus() async {
        let model = makeModel(MockAgent(enrolled: true))
        await model.refresh()
        #expect(model.connection == .connected)
        #expect(model.status == AgentStatusSnapshot(enabled: false, enrolled: true, lockedOut: false))
        #expect(model.canEnable)
    }

    @Test func unreachableAgent() async {
        let agent = MockAgent()
        await agent.configure { $0.reachable = false }
        let model = makeModel(agent)
        await model.refresh()
        #expect(model.connection == .unreachable)
        #expect(model.status == nil)
    }

    @Test func cannotEnableWithoutEnrollment() async {
        let settings = MockEnabledSetting()
        let model = makeModel(MockAgent(enrolled: false), settings: settings)
        await model.refresh()
        await model.setEnabled(true)
        #expect(settings.history.isEmpty)
    }

    @Test func enableWritesSharedSetting() async {
        let settings = MockEnabledSetting()
        let model = makeModel(MockAgent(enrolled: true), settings: settings)
        await model.refresh()
        await model.setEnabled(true)
        #expect(settings.history == [true])
    }

    @Test func disablingAlwaysWorksEvenWhenAgentIsDown() async {
        let agent = MockAgent(enrolled: true)
        await agent.configure { $0.reachable = false }
        let settings = MockEnabledSetting()
        let model = makeModel(agent, settings: settings)
        await model.refresh()
        await model.setEnabled(false)
        #expect(settings.history == [false])
    }

    @Test func enrollmentRequiresAcknowledgingTheWarning() async {
        let agent = MockAgent()
        let model = makeModel(agent)
        await model.refresh()
        await model.startEnrollment()
        #expect(await agent.startCalls == 0)
        #expect(model.enrollment == nil)
    }

    @Test func cameraDeniedStopsBeforeEnrolling() async {
        let agent = MockAgent()
        await agent.configure { $0.cameraGranted = false }
        let model = makeModel(agent)
        await model.refresh()
        model.warningAcknowledged = true
        await model.startEnrollment()
        #expect(model.cameraDenied)
        #expect(model.notice == AppStrings.cameraDenied)
        #expect(await agent.startCalls == 0)
    }

    @Test func enrollmentPollsUntilCompleted() async {
        let agent = MockAgent()
        await agent.configure {
            $0.enrollmentScript = [
                EnrollmentSnapshot(state: .capturing, nextPose: .front, fraction: 0, blinkDetected: false),
                EnrollmentSnapshot(state: .capturing, nextPose: .left, fraction: 0.4, blinkDetected: true),
                EnrollmentSnapshot(state: .verifyingOwner, nextPose: nil, fraction: 1, blinkDetected: true),
                EnrollmentSnapshot(state: .completed, nextPose: nil, fraction: 1, blinkDetected: true),
            ]
        }
        let model = makeModel(agent)
        await model.refresh()
        model.warningAcknowledged = true
        await model.startEnrollment()
        #expect(model.isEnrolling)

        await model.waitForEnrollmentToFinish()
        #expect(!model.isEnrolling)
        #expect(model.notice == AppStrings.enrollmentDone)
        #expect(model.status?.enrolled == true)
        #expect(!model.warningAcknowledged)
    }

    @Test(arguments: [EnrollmentState.failed, .cancelled])
    func unsuccessfulEnrollmentIsReported(state: EnrollmentState) async {
        let agent = MockAgent()
        await agent.configure {
            $0.enrollmentScript = [EnrollmentSnapshot(state: state, nextPose: nil, fraction: 0, blinkDetected: false)]
        }
        let model = makeModel(agent)
        await model.refresh()
        model.warningAcknowledged = true
        await model.startEnrollment()
        await model.waitForEnrollmentToFinish()
        #expect(model.notice == (state == .failed ? AppStrings.enrollmentFailed : AppStrings.enrollmentCancelled))
        #expect(model.status?.enrolled == false)
    }

    @Test func agentDisappearingDuringEnrollment() async {
        let agent = MockAgent()
        await agent.configure {
            $0.enrollmentScript = [EnrollmentSnapshot(state: .capturing, nextPose: .front, fraction: 0, blinkDetected: false)]
        }
        let model = makeModel(agent)
        await model.refresh()
        model.warningAcknowledged = true
        await model.startEnrollment()
        await agent.configure { $0.reachable = false }
        await model.waitForEnrollmentToFinish()
        #expect(model.connection == .unreachable)
        #expect(model.enrollment == nil)
    }

    @Test func cancelIsForwarded() async {
        let agent = MockAgent()
        let model = makeModel(agent)
        await model.cancelEnrollment()
        #expect(await agent.cancelCalls == 1)
    }

    @Test func deleteDisablesFirstThenDeletes() async {
        let agent = MockAgent(enrolled: true)
        let settings = MockEnabledSetting()
        let model = makeModel(agent, settings: settings)
        await model.refresh()
        await model.deleteEnrollment()
        #expect(settings.history == [false])
        #expect(model.notice == AppStrings.deleteDone)
        #expect(model.status?.enrolled == false)
    }

    @Test func failedDeleteIsReported() async {
        let agent = MockAgent(enrolled: true)
        await agent.configure { $0.deleteSucceeds = false }
        let model = makeModel(agent)
        await model.refresh()
        await model.deleteEnrollment()
        #expect(model.notice == AppStrings.deleteFailed)
        #expect(model.status?.enrolled == true)
    }

    @Test func menuBarSymbolShowsLockout() async {
        let agent = MockAgent(enrolled: true)
        await agent.configure { $0.lockedOut = true }
        let model = makeModel(agent)
        await model.refresh()
        #expect(model.menuBarSymbol == "lock.fill")
    }

    @Test(arguments: [
        (AuthResultCode.match, AppStrings.testScanMatch),
        (.noMatch, AppStrings.testScanNoMatch),
        (.livenessFailed, AppStrings.testScanLiveness),
        (.timeout, AppStrings.testScanTimeout),
        (.error, AppStrings.testScanError),
    ])
    func testScanReportsEachOutcome(result: AuthResultCode, message: String) async {
        let agent = MockAgent(enrolled: true)
        await agent.configure { $0.enabled = true; $0.scanResult = result }
        let model = makeModel(agent)
        await model.refresh()
        await model.testScan()
        #expect(model.notice == message)
        #expect(!model.isTestScanning)
        #expect(await agent.scanCalls == 1)
    }

    @Test func testScanNeedsAConnectedAgent() async {
        let agent = MockAgent(enrolled: true)
        let model = makeModel(agent)
        // Not refreshed yet: connection unknown.
        await model.testScan()
        #expect(await agent.scanCalls == 0)
    }

    @Test func testScanReportsUnreachableAgent() async {
        let agent = MockAgent(enrolled: true)
        let model = makeModel(agent)
        await model.refresh()
        await agent.configure { $0.reachable = false }
        await model.testScan()
        #expect(model.notice == AppStrings.agentUnreachable)
    }

    @Test func approvalAfterAnUpdate() async {
        let agent = MockAgent(enrolled: true)
        await agent.configure { $0.needsApproval = true }
        let model = makeModel(agent)
        await model.refresh()
        #expect(model.status?.needsKeychainApproval == true)
        await model.approveKeychainAccess()
        #expect(model.notice == AppStrings.approveKeychainDone)
        #expect(model.status?.needsKeychainApproval == false)
        #expect(await agent.approveCalls == 1)
    }

    @Test func deniedApprovalIsExplained() async {
        let agent = MockAgent(enrolled: true)
        await agent.configure { $0.needsApproval = true; $0.approvalGranted = false }
        let model = makeModel(agent)
        await model.refresh()
        await model.approveKeychainAccess()
        #expect(model.notice == AppStrings.approveKeychainFailed)
        #expect(model.status?.needsKeychainApproval == true)
    }

    @Test func enrollmentWarningIsTheTwoDCameraWarning() {
        #expect(AppStrings.warning == FaceIDStrings.twoDCameraWarning)
        #expect(AppStrings.warning.contains("2D"))
    }
}

struct AgentRequirementTests {
    @Test func appPinsTheAgentIdentifierAndCertificate() {
        let requirement = FaceIDXPC.agentRequirement(certificateSHA1: "0123456789ABCDEF0123456789ABCDEF01234567")
        #expect(requirement == #"identifier "com.example.faceid.agent" and certificate leaf = H"0123456789ABCDEF0123456789ABCDEF01234567""#)
        var compiled: SecRequirement?
        #expect(SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess)
    }
}
