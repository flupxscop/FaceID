import CoreGraphics
import Foundation

public enum AuthOutcome: Sendable, Equatable {
    case match
    case noMatch
    case livenessFailed
    case timeout
    case error(FaceIDError)
}

/// Runs one unlock attempt: camera → quality gate → liveness → embedding → matching.
/// Anything other than `.match` must make the caller fall back to the password.
public actor FaceAuthenticator {
    private let camera: any CameraProviding
    private let analyzer: any FaceAnalyzing
    private let embedder: any EmbeddingProviding
    private let store: any TemplateStoring
    private let matcher: Matcher
    private let qualityGate: QualityGate
    private let livenessConfig: LivenessConfig
    private let timeout: Duration
    private let requiredConsecutiveMatches: Int
    private let challengeProvider: @Sendable () -> LivenessChallenge

    private var limiter: AttemptLimiter
    private var isScanning = false

    public init(
        camera: any CameraProviding,
        analyzer: any FaceAnalyzing,
        embedder: any EmbeddingProviding,
        store: any TemplateStoring,
        matcher: Matcher = Matcher(),
        qualityGate: QualityGate = QualityGate(),
        livenessConfig: LivenessConfig = LivenessConfig(),
        timeout: Duration = FaceIDConfig.scanTimeout,
        requiredConsecutiveMatches: Int = FaceIDConfig.requiredConsecutiveMatches,
        maxAttempts: Int = FaceIDConfig.maxAttemptsBeforeLockout,
        challengeProvider: @escaping @Sendable () -> LivenessChallenge = { LivenessChallenge.random() }
    ) {
        self.camera = camera
        self.analyzer = analyzer
        self.embedder = embedder
        self.store = store
        self.matcher = matcher
        self.qualityGate = qualityGate
        self.livenessConfig = livenessConfig
        self.timeout = timeout
        self.requiredConsecutiveMatches = requiredConsecutiveMatches
        self.challengeProvider = challengeProvider
        self.limiter = AttemptLimiter(maxAttempts: maxAttempts)
    }

    public var isLockedOut: Bool { limiter.isLockedOut }

    /// Call only after the system confirmed the user's password.
    public func resetAfterPasswordAuthentication() {
        limiter.resetAfterPasswordAuthentication()
    }

    public func authenticate() async -> AuthOutcome {
        guard !limiter.isLockedOut else { return .error(.lockedOut) }
        guard !isScanning else { return .error(.busy) }
        isScanning = true
        defer { isScanning = false }

        let template: EnrolledTemplate
        do {
            guard let loaded = try store.load() else { return .error(.notEnrolled) }
            template = loaded
        } catch let error as FaceIDError {
            return .error(error)
        } catch {
            return .error(.internalFailure)
        }
        guard !template.embeddings.isEmpty, template.modelIdentifier == embedder.modelIdentifier else {
            return .error(.invalidTemplate)
        }

        let context = ScanContext(
            camera: camera,
            analyzer: analyzer,
            embedder: embedder,
            matcher: matcher,
            qualityGate: qualityGate,
            livenessConfig: livenessConfig,
            requiredConsecutiveMatches: requiredConsecutiveMatches,
            challenge: challengeProvider(),
            templates: template.embeddings
        )
        var outcome = await Self.runScan(context, timeout: timeout)
        await camera.stop()

        if Task.isCancelled, outcome != .match {
            outcome = .error(.cancelled)
        }
        switch outcome {
        case .match:
            limiter.recordSuccess()
        case .noMatch, .livenessFailed:
            limiter.recordFailure()
        case .timeout, .error:
            break
        }
        Log.auth.info("scan finished: \(String(describing: outcome.resultCode), privacy: .public)")
        return outcome
    }

    // MARK: - Scan

    private struct ScanContext: Sendable {
        let camera: any CameraProviding
        let analyzer: any FaceAnalyzing
        let embedder: any EmbeddingProviding
        let matcher: Matcher
        let qualityGate: QualityGate
        let livenessConfig: LivenessConfig
        let requiredConsecutiveMatches: Int
        let challenge: LivenessChallenge
        let templates: [FaceEmbedding]
    }

    private struct ScanSummary: Sendable {
        var outcome: AuthOutcome?
        var comparedEmbedding = false
        var livenessPassed = false
        var reachedMatchStreak = false

        /// Outcome when the scan ended without a definitive result (timeout or stream end).
        var resolved: AuthOutcome {
            if let outcome { return outcome }
            if reachedMatchStreak && !livenessPassed { return .livenessFailed }
            if comparedEmbedding { return .noMatch }
            return .timeout
        }
    }

    private enum ScanEvent: Sendable {
        case finished(ScanSummary)
        case timedOut
    }

    static func isContinuous(_ a: CGRect, _ b: CGRect) -> Bool {
        let jump = hypot(Double(a.midX - b.midX), Double(a.midY - b.midY))
        guard a.width > 0, b.width > 0 else { return false }
        let scale = Double(max(a.width, b.width) / min(a.width, b.width))
        return jump <= maxFaceJump && scale <= maxFaceScaleChange
    }

    private static func runScan(_ context: ScanContext, timeout: Duration) async -> AuthOutcome {
        await withTaskGroup(of: ScanEvent.self) { group in
            group.addTask { .finished(await scan(context)) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            while let event = await group.next() {
                switch event {
                case .finished(let summary):
                    group.cancelAll()
                    return summary.resolved
                case .timedOut:
                    // Cancelling makes the scan task return its summary so far.
                    group.cancelAll()
                }
            }
            return .timeout
        }
    }

    /// Largest plausible movement of the face centre between two frames (normalised image units).
    static let maxFaceJump = 0.2
    /// Largest plausible change of the face width between two frames (ratio).
    static let maxFaceScaleChange = 1.6

    private static func scan(_ context: ScanContext) async -> ScanSummary {
        var summary = ScanSummary()
        var liveness = LivenessChecker(challenge: context.challenge, config: context.livenessConfig)
        var streak = ConsecutiveMatchTracker(required: context.requiredConsecutiveMatches)
        // Liveness only counts for the face that matched: it is collected after a match ("anchored")
        // and thrown away whenever identity continuity breaks. Otherwise an attacker could blink and
        // turn with their own face, then hold up a photo of the owner for the matching frames.
        var anchored = false
        var lastBox: CGRect?

        func breakContinuity() {
            streak.reset()
            liveness = LivenessChecker(challenge: context.challenge, config: context.livenessConfig)
            summary.livenessPassed = false
            anchored = false
        }

        var diagnostics = FrameDiagnostics(label: "scan")
        do {
            let frames = try await context.camera.frames()
            for try await frame in frames {
                if Task.isCancelled { break }
                let analysis = try await context.analyzer.analyze(frame)
                if let line = diagnostics.record(analysis, issue: context.qualityGate.evaluate(analysis)) {
                    Log.auth.notice("\(line, privacy: .public), liveness passed \(summary.livenessPassed, privacy: .public)")
                }

                // Identity must stay continuous: losing the face or seeing a second one starts over.
                guard analysis.faces.count == 1, let face = analysis.faces.first else {
                    breakContinuity()
                    lastBox = nil
                    continue
                }
                // A face that jumps or changes size abruptly is treated as a different face.
                if let previous = lastBox, !Self.isContinuous(previous, face.boundingBox) {
                    breakContinuity()
                }
                lastBox = face.boundingBox

                // Liveness sees every single-face frame of the anchored face: blinking frames often
                // fail the quality gate, but continuity above ties them to the matched face.
                if anchored, let sample = LivenessSample(face: face, timestamp: analysis.timestamp),
                   liveness.add(sample) == .passed {
                    summary.livenessPassed = true
                }

                if context.qualityGate.evaluate(analysis) != nil { continue }

                let probe = try await context.embedder.embedding(for: frame, face: face)
                summary.comparedEmbedding = true
                let matched = context.matcher.matches(probe, templates: context.templates)
                guard matched else {
                    breakContinuity()
                    continue
                }
                anchored = true
                if streak.record(true) {
                    summary.reachedMatchStreak = true
                }

                if summary.livenessPassed && streak.isSatisfied {
                    summary.outcome = .match
                    break
                }
            }
        } catch is CancellationError {
            // Timeout or caller cancellation; the summary so far decides the outcome.
        } catch let error as FaceIDError {
            Log.auth.error("scan failed: \(String(describing: error), privacy: .public)")
            summary.outcome = .error(error)
        } catch {
            summary.outcome = .error(.internalFailure)
        }
        return summary
    }
}
