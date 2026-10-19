import AppKit
import FaceIDAppKit
import FaceIDCore
import SwiftUI

struct MenuContentView: View {
    @Bindable var model: AppModel
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch model.connection {
            case .unsigned:
                ProblemView(text: AppStrings.appUnsigned)
            case .unreachable:
                ProblemView(text: AppStrings.agentUnreachable)
                // Turning the feature off must always be possible, even without the agent.
                Button(AppStrings.enableToggle + ": ปิด") {
                    Task { await model.setEnabled(false) }
                }
            case .unknown:
                ProgressView().controlSize(.small)
            case .connected:
                connectedContent
            }

            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.cameraDenied {
                Button(AppStrings.openCameraSettings) { openCameraSettings() }
            }

            Divider()
            Button(AppStrings.quit) { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 340)
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack {
            Image(systemName: model.menuBarSymbol)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppStrings.title).font(.headline)
                Text(AppStrings.passwordAlwaysWorks)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var connectedContent: some View {
        Toggle(AppStrings.enableToggle, isOn: Binding(
            get: { model.isEnabled },
            set: { newValue in Task { await model.setEnabled(newValue) } }
        ))
        .toggleStyle(.switch)
        .disabled(!model.isEnabled && !model.canEnable)

        if let status = model.status {
            Label(status.enrolled ? AppStrings.enrolled : AppStrings.notEnrolled,
                  systemImage: status.enrolled ? "checkmark.circle" : "circle.dashed")
                .font(.callout)
            if status.needsKeychainApproval {
                VStack(alignment: .leading, spacing: 4) {
                    Label(AppStrings.keychainApprovalNeeded, systemImage: "key")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(AppStrings.approveKeychain) {
                        Task { await model.approveKeychainAccess() }
                    }
                    .disabled(model.isApproving)
                    Text(AppStrings.approveKeychainHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if status.lockedOut {
                Label(AppStrings.lockedOut, systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }

        Divider()

        if model.isEnabled && model.status?.enrolled == true && !model.isEnrolling {
            VStack(alignment: .leading, spacing: 4) {
                Button(AppStrings.testScan) {
                    Task { await model.testScan() }
                }
                .disabled(model.isTestScanning)
                Text(AppStrings.testScanHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
        }

        if let enrollment = model.enrollment, enrollment.isRunning {
            EnrollmentProgressView(enrollment: enrollment) {
                Task { await model.cancelEnrollment() }
            }
        } else {
            enrollmentStart
        }
    }

    @ViewBuilder
    private var enrollmentStart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppStrings.warningTitle).font(.subheadline.bold())
            Text(AppStrings.warning)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text(AppStrings.privacyNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(AppStrings.acknowledge, isOn: $model.warningAcknowledged)
                .toggleStyle(.checkbox)

            HStack {
                Button(model.status?.enrolled == true ? AppStrings.reEnroll : AppStrings.enroll) {
                    Task { await model.startEnrollment() }
                }
                .disabled(!model.warningAcknowledged)

                Spacer()

                if model.status?.enrolled == true {
                    if confirmingDelete {
                        Button(AppStrings.cancel) { confirmingDelete = false }
                        Button(AppStrings.deleteConfirm, role: .destructive) {
                            confirmingDelete = false
                            Task { await model.deleteEnrollment() }
                        }
                    } else {
                        Button(AppStrings.delete, role: .destructive) { confirmingDelete = true }
                    }
                }
            }
        }
    }

    private func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct ProblemView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Instructions only — the app never shows (or receives) camera images.
private struct EnrollmentProgressView: View {
    let enrollment: EnrollmentSnapshot
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if enrollment.state == .verifyingOwner {
                Label(AppStrings.verifyingOwner, systemImage: "key")
            } else {
                Text(enrollment.nextPose?.instruction ?? EnrollmentPose.front.instruction)
                    .font(.title3.bold())
                ProgressView(value: enrollment.fraction)
                Label(AppStrings.blinkHint, systemImage: enrollment.blinkDetected ? "checkmark.circle.fill" : "eye")
                    .font(.callout)
                    .foregroundStyle(enrollment.blinkDetected ? .green : .secondary)
            }
            Button(AppStrings.cancel, action: onCancel)
        }
    }
}
