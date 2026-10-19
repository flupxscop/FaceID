import CoreGraphics
import Foundation

public enum QualityIssue: String, Sendable, Equatable {
    case noFace
    case multipleFaces
    case faceTooSmall
    case badPose
    /// No 5-point alignment landmarks: the embedding would not match the model's training.
    case missingLandmarks
    case lowCaptureQuality
    case unmeasurable
    case tooDark
    case tooBright
    case blurry
}

public struct QualityThresholds: Sendable, Equatable {
    public var minFaceCaptureQuality: Float = FaceIDConfig.minFaceCaptureQuality
    /// Face width as a fraction of the frame width.
    public var minFaceWidth: Double = 0.18
    public var maxAbsYawDegrees: Double = 30
    public var maxAbsPitchDegrees: Double = 25
    public var maxAbsRollDegrees: Double = 25
    public var minBrightness: Double = 0.15
    public var maxBrightness: Double = 0.92
    /// Laplacian variance on 0...255 luma. Calibrate with the real camera.
    public var minSharpness: Double = 15

    public init() {}
}

/// Rejects frames that are unsuitable for matching. Missing measurements count as failures (fail closed).
public struct QualityGate: Sendable {
    public var thresholds: QualityThresholds

    public init(thresholds: QualityThresholds = QualityThresholds()) {
        self.thresholds = thresholds
    }

    /// Returns the first problem found, or nil when the frame is usable.
    public func evaluate(_ analysis: FrameAnalysis) -> QualityIssue? {
        guard let face = analysis.faces.first else { return .noFace }
        // A second face could be a bystander or a spoof held next to the user.
        guard analysis.faces.count == 1 else { return .multipleFaces }

        if face.boundingBox.width < thresholds.minFaceWidth { return .faceTooSmall }

        if exceeds(face.yawDegrees, thresholds.maxAbsYawDegrees)
            || exceeds(face.pitchDegrees, thresholds.maxAbsPitchDegrees)
            || exceeds(face.rollDegrees, thresholds.maxAbsRollDegrees) {
            return .badPose
        }

        guard face.landmarks?.alignmentPoints?.count == FaceAlignment.referencePoints.count else {
            return .missingLandmarks
        }

        guard let quality = face.captureQuality, quality >= thresholds.minFaceCaptureQuality else {
            return .lowCaptureQuality
        }

        guard let metrics = analysis.metrics else { return .unmeasurable }
        if metrics.brightness < thresholds.minBrightness { return .tooDark }
        if metrics.brightness > thresholds.maxBrightness { return .tooBright }
        if metrics.sharpness < thresholds.minSharpness { return .blurry }
        return nil
    }

    private func exceeds(_ angle: Double?, _ limit: Double) -> Bool {
        guard let angle else { return false }
        return !angle.isFinite || abs(angle) > limit
    }
}
