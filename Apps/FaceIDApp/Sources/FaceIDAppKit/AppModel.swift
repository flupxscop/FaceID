import FaceIDCore
import Foundation
import Observation

@MainActor
@Observable
public final class AppModel {
    public enum AgentConnection: Equatable, Sendable {
        case unknown
        case connected
        case unreachable
        /// This app has no signing certificate, so it cannot verify (or be accepted by) the agent.
        case unsigned
    }

    public private(set) var connection: AgentConnection = .unknown
    public private(set) var status: AgentStatusSnapshot?
    public private(set) var enrollment: EnrollmentSnapshot?
    public private(set) var notice: String?
    public private(set) var cameraDenied = false
    public private(set) var isTestScanning = false
    public private(set) var isApproving = false
    public var warningAcknowledged = false

    private let client: (any AgentClient)?
    private let settings: any EnabledSettingStoring
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?

    public init(client: (any AgentClient)?, settings: any EnabledSettingStoring, pollInterval: Duration = .milliseconds(250)) {
        self.client = client
        self.settings = settings
        self.pollInterval = pollInterval
        if client == nil { connection = .unsigned }
    }

    public var isEnrolling: Bool { enrollment?.isRunning ?? false }
    public var isEnabled: Bool { status?.enabled ?? false }
    public var canEnable: Bool { connection == .connected && status?.enrolled == true }

    public var menuBarSymbol: String {
        guard connection == .connected, let status else { return "faceid" }
        if status.lockedOut { return "lock.fill" }
        return status.enabled ? "faceid" : "person.crop.circle.badge.xmark"
    }

    public func refresh() async {
        guard let client else {
            connection = .unsigned
            return
        }
        do {
            status = try await client.status()
            connection = .connected
        } catch {
            status = nil
            connection = .unreachable
        }
    }

    /// One click: turning off always works, even if the agent is unreachable.
    public func setEnabled(_ enabled: Bool) async {
        if enabled && !canEnable { return }
        settings.setEnabled(enabled)
        await refresh()
    }

    public func startEnrollment() async {
        guard let client, warningAcknowledged, !isEnrolling else { return }
        notice = nil
        cameraDenied = false
        do {
            guard try await client.requestCameraAccess() else {
                cameraDenied = true
                notice = AppStrings.cameraDenied
                return
            }
            guard try await client.startEnrollment() else {
                notice = AppStrings.enrollmentBusy
                return
            }
        } catch {
            connection = .unreachable
            notice = AppStrings.agentUnreachable
            return
        }
        enrollment = EnrollmentSnapshot(state: .capturing, nextPose: .front, fraction: 0, blinkDetected: false)
        startPolling(client)
    }

    /// After an agent update: lets the owner allow keychain access again instead of re-enrolling.
    public func approveKeychainAccess() async {
        guard let client, connection == .connected, !isApproving else { return }
        isApproving = true
        defer { isApproving = false }
        do {
            notice = try await client.approveKeychainAccess() ? AppStrings.approveKeychainDone : AppStrings.approveKeychainFailed
        } catch {
            notice = AppStrings.agentUnreachable
        }
        await refresh()
    }

    /// Runs one scan and reports the result. Never unlocks anything.
    public func testScan() async {
        guard let client, connection == .connected, !isEnrolling, !isTestScanning else { return }
        isTestScanning = true
        notice = AppStrings.testScanRunning
        defer { isTestScanning = false }
        do {
            switch try await client.testScan() {
            case .match: notice = AppStrings.testScanMatch
            case .noMatch: notice = AppStrings.testScanNoMatch
            case .livenessFailed: notice = AppStrings.testScanLiveness
            case .timeout: notice = AppStrings.testScanTimeout
            case .error: notice = AppStrings.testScanError
            }
        } catch {
            notice = AppStrings.agentUnreachable
        }
        await refresh()
    }

    public func cancelEnrollment() async {
        await client?.cancelEnrollment()
    }

    public func deleteEnrollment() async {
        // Disable first, so nothing can scan against a half-deleted state.
        settings.setEnabled(false)
        let deleted = (try? await client?.deleteEnrollment()) ?? false
        notice = deleted ? AppStrings.deleteDone : AppStrings.deleteFailed
        await refresh()
    }

    /// Waits until the current enrollment poll loop ends (tests).
    public func waitForEnrollmentToFinish() async {
        await pollTask?.value
    }

    private func startPolling(_ client: any AgentClient) {
        pollTask?.cancel()
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                let snapshot = try? await client.enrollmentStatus()
                guard let self else { return }
                guard let snapshot else {
                    self.connection = .unreachable
                    self.enrollment = nil
                    self.notice = AppStrings.agentUnreachable
                    return
                }
                self.enrollment = snapshot
                if !snapshot.isRunning {
                    await self.enrollmentEnded(snapshot)
                    return
                }
            }
        }
    }

    private func enrollmentEnded(_ snapshot: EnrollmentSnapshot) async {
        switch snapshot.state {
        case .completed:
            notice = AppStrings.enrollmentDone
            warningAcknowledged = false
        case .cancelled:
            notice = AppStrings.enrollmentCancelled
        default:
            notice = AppStrings.enrollmentFailed
        }
        enrollment = nil
        await refresh()
    }
}
