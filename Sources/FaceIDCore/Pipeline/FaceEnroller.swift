import Foundation
import LocalAuthentication

/// Confirms the device owner (password or Touch ID) through the system UI.
/// We never see or handle the password itself.
public protocol OwnerVerifying: Sendable {
    func verifyOwner(reason: String) async -> Bool
}

public struct LocalAuthenticationOwnerVerifier: OwnerVerifying {
    public init() {}

    public func verifyOwner(reason: String) async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            // LAError codes: -2 user cancel, -1 auth failed, -4 system cancel, -9 app cancel, -1004 not interactive.
            Log.auth.error("owner verification error \((error as NSError).code, privacy: .public)")
            return false
        }
    }
}

public enum EnrollmentState: Int, Sendable {
    case idle = 0
    case capturing = 1
    case verifyingOwner = 2
    case completed = 3
    case failed = 4
    case cancelled = 5
}

/// What the UI may learn about an enrollment. Deliberately contains no images or embeddings.
public struct EnrollmentProgress: Sendable, Equatable {
    public var state: EnrollmentState
    public var nextPose: EnrollmentPose?
    public var fraction: Double
    public var blinkDetected: Bool
    public var error: FaceIDError?

    public init(state: EnrollmentState, nextPose: EnrollmentPose?, fraction: Double, blinkDetected: Bool, error: FaceIDError?) {
        self.state = state
        self.nextPose = nextPose
        self.fraction = fraction
        self.blinkDetected = blinkDetected
        self.error = error
    }

    public static let idle = EnrollmentProgress(state: .idle, nextPose: nil, fraction: 0, blinkDetected: false, error: nil)
}

/// Captures a new template inside the agent, so camera frames and embeddings never cross a
/// process boundary. The owner must confirm with their password before the template is saved;
/// otherwise every captured embedding is discarded.
public actor FaceEnroller {
    public static let verificationReason = "ยืนยันตัวตนเพื่อบันทึกใบหน้าสำหรับปลดล็อก Mac"

    private let camera: any CameraProviding
    private let analyzer: any FaceAnalyzing
    private let embedder: any EmbeddingProviding
    private let store: any TemplateStoring
    private let ownerVerifier: any OwnerVerifying
    private let qualityGate: QualityGate
    private let livenessConfig: LivenessConfig
    private let timeout: Duration

    public private(set) var progress = EnrollmentProgress.idle

    public init(
        camera: any CameraProviding,
        analyzer: any FaceAnalyzing,
        embedder: any EmbeddingProviding,
        store: any TemplateStoring,
        ownerVerifier: any OwnerVerifying,
        qualityGate: QualityGate = QualityGate(),
        livenessConfig: LivenessConfig = LivenessConfig(),
        timeout: Duration = .seconds(60)
    ) {
        self.camera = camera
        self.analyzer = analyzer
        self.embedder = embedder
        self.store = store
        self.ownerVerifier = ownerVerifier
        self.qualityGate = qualityGate
        self.livenessConfig = livenessConfig
        self.timeout = timeout
    }

    public func enroll() async -> EnrollmentProgress {
        guard progress.state != .capturing, progress.state != .verifyingOwner else {
            return EnrollmentProgress(state: .failed, nextPose: nil, fraction: 0, blinkDetected: false, error: .busy)
        }
        progress = EnrollmentProgress(state: .capturing, nextPose: .front, fraction: 0, blinkDetected: false, error: nil)

        let context = CaptureContext(
            camera: camera, analyzer: analyzer, embedder: embedder,
            qualityGate: qualityGate, livenessConfig: livenessConfig
        )
        var result = await Self.runCapture(context, timeout: timeout) { [weak self] session, blink in
            await self?.report(session, blinkDetected: blink)
        }
        await camera.stop()
        if Task.isCancelled { result = .failed(.cancelled) }

        let session: EnrollmentSession
        switch result {
        case .complete(let captured):
            session = captured
        case .failed(let error):
            return finish(error)
        }

        progress.state = .verifyingOwner
        Log.auth.notice("enrollment: asking the owner for the password")
        guard await ownerVerifier.verifyOwner(reason: Self.verificationReason) else {
            Log.auth.error("enrollment: owner verification failed")
            return finish(.ownerVerificationFailed)
        }
        guard !Task.isCancelled else { return finish(.cancelled) }

        do {
            try store.save(try session.makeTemplate(modelIdentifier: embedder.modelIdentifier))
        } catch let error as FaceIDError {
            return finish(error)
        } catch {
            return finish(.internalFailure)
        }
        progress = EnrollmentProgress(state: .completed, nextPose: nil, fraction: 1, blinkDetected: true, error: nil)
        return progress
    }

    private func report(_ session: EnrollmentSession, blinkDetected: Bool) {
        guard progress.state == .capturing else { return }
        progress.nextPose = session.nextPose
        progress.fraction = session.progress
        progress.blinkDetected = blinkDetected
    }

    private func finish(_ error: FaceIDError) -> EnrollmentProgress {
        Log.auth.notice("enrollment finished: \(String(describing: error), privacy: .public)")
        let state: EnrollmentState = error == .cancelled ? .cancelled : .failed
        progress = EnrollmentProgress(state: state, nextPose: nil, fraction: 0, blinkDetected: false, error: error)
        return progress
    }

    // MARK: - Capture

    private struct CaptureContext: Sendable {
        let camera: any CameraProviding
        let analyzer: any FaceAnalyzing
        let embedder: any EmbeddingProviding
        let qualityGate: QualityGate
        let livenessConfig: LivenessConfig
    }

    private enum CaptureResult: Sendable {
        case complete(EnrollmentSession)
        case failed(FaceIDError)
    }

    private typealias Reporter = @Sendable (EnrollmentSession, Bool) async -> Void

    private static func runCapture(_ context: CaptureContext, timeout: Duration, report: @escaping Reporter) async -> CaptureResult {
        await withTaskGroup(of: CaptureResult.self) { group in
            group.addTask { await capture(context, report: report) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .failed(.enrollmentTimedOut)
            }
            let first = await group.next() ?? .failed(.internalFailure)
            group.cancelAll()
            return first
        }
    }

    private static func capture(_ context: CaptureContext, report: Reporter) async -> CaptureResult {
        var session = EnrollmentSession()
        // Enrollment poses already include head turns; liveness here only demands a natural blink,
        // so a photo cannot be enrolled.
        var liveness = LivenessChecker(challenge: .turnLeft, config: context.livenessConfig)
        var reportedBlink = false
        var diagnostics = FrameDiagnostics(label: "enrollment")

        do {
            let frames = try await context.camera.frames()
            Log.auth.notice("enrollment: camera started")
            for try await frame in frames {
                if Task.isCancelled { return .failed(.cancelled) }
                let analysis = try await context.analyzer.analyze(frame)
                guard analysis.faces.count == 1, let face = analysis.faces.first else {
                    if let line = diagnostics.record(analysis, issue: context.qualityGate.evaluate(analysis)) {
                        Log.auth.notice("\(line, privacy: .public), next pose \(session.nextPose?.rawValue ?? "-", privacy: .public)")
                    }
                    continue
                }

                if let sample = LivenessSample(face: face, timestamp: analysis.timestamp) {
                    liveness.add(sample)
                }
                let blinked = liveness.blinkCount >= context.livenessConfig.requiredBlinks

                var accepted = false
                let issue = context.qualityGate.evaluate(analysis)
                if issue == nil {
                    let embedding = try await context.embedder.embedding(for: frame, face: face)
                    accepted = session.consider(face: face, embedding: embedding) != nil
                }
                let skipped = issue == nil && !accepted ? session.lastRejection?.rawValue : nil
                if let line = diagnostics.record(analysis, issue: issue, accepted: accepted, notStoredBecause: skipped) {
                    let base = session.baseline.map { "yaw \(Int($0.yaw.rounded())) pitch \(Int($0.pitch.rounded()))" } ?? "calibrating"
                    Log.auth.notice("\(line, privacy: .public), natural pose \(base, privacy: .public), next pose \(session.nextPose?.rawValue ?? "-", privacy: .public), blink \(blinked, privacy: .public)")
                }
                if accepted || blinked != reportedBlink {
                    reportedBlink = blinked
                    await report(session, blinked)
                }
                if session.isComplete && blinked {
                    Log.auth.notice("enrollment: all poses captured")
                    return .complete(session)
                }
            }
            return .failed(Task.isCancelled ? .cancelled : .enrollmentTimedOut)
        } catch is CancellationError {
            return .failed(.cancelled)
        } catch let error as FaceIDError {
            Log.auth.error("enrollment failed: \(String(describing: error), privacy: .public)")
            return .failed(error)
        } catch {
            return .failed(.internalFailure)
        }
    }
}
