import CoreGraphics
import Foundation

public enum EyeAspectRatio {
    /// Height/width ratio of an eye contour. Roll-invariant: the eye corners are taken as the
    /// farthest-apart pair of points and the height is measured perpendicular to that axis.
    /// Open eyes are typically ~0.25–0.35, closed eyes well below 0.15.
    public static func compute(_ points: [CGPoint]) -> Double? {
        guard points.count >= 4 else { return nil }

        var corners = (points[0], points[1])
        var widest = 0.0
        for i in points.indices {
            for j in points.indices where j > i {
                let d = hypot(points[j].x - points[i].x, points[j].y - points[i].y)
                if d > widest {
                    widest = d
                    corners = (points[i], points[j])
                }
            }
        }
        guard widest > 0, widest.isFinite else { return nil }

        let ux = (corners.1.x - corners.0.x) / widest
        let uy = (corners.1.y - corners.0.y) / widest
        let offsets = points.map { -uy * ($0.x - corners.0.x) + ux * ($0.y - corners.0.y) }
        guard let low = offsets.min(), let high = offsets.max() else { return nil }
        return (high - low) / widest
    }
}

/// A random head-turn the user must perform, so a pre-recorded video is unlikely to pass.
public enum LivenessChallenge: Sendable, Equatable, CaseIterable {
    case turnLeft
    case turnRight

    public static func random() -> LivenessChallenge {
        Bool.random() ? .turnLeft : .turnRight
    }

    /// Sign of the yaw change that satisfies this challenge.
    var yawSign: Double {
        switch self {
        case .turnLeft: HeadPoseConvention.leftTurnYawSign
        case .turnRight: -HeadPoseConvention.leftTurnYawSign
        }
    }
}

public struct LivenessSample: Sendable, Equatable {
    public var timestamp: TimeInterval
    public var leftEyeAspectRatio: Double
    public var rightEyeAspectRatio: Double
    public var yawDegrees: Double

    public init(timestamp: TimeInterval, leftEyeAspectRatio: Double, rightEyeAspectRatio: Double, yawDegrees: Double) {
        self.timestamp = timestamp
        self.leftEyeAspectRatio = leftEyeAspectRatio
        self.rightEyeAspectRatio = rightEyeAspectRatio
        self.yawDegrees = yawDegrees
    }

    /// Builds a sample from a face observation; nil when landmarks or yaw are missing.
    public init?(face: FaceObservation, timestamp: TimeInterval) {
        guard let landmarks = face.landmarks,
              let yaw = face.yawDegrees, yaw.isFinite,
              let left = EyeAspectRatio.compute(landmarks.leftEye),
              let right = EyeAspectRatio.compute(landmarks.rightEye)
        else { return nil }
        self.init(timestamp: timestamp, leftEyeAspectRatio: left, rightEyeAspectRatio: right, yawDegrees: yaw)
    }
}

public struct LivenessConfig: Sendable, Equatable {
    /// Samples used to establish the open-eye and resting-yaw baselines.
    public var baselineSamples = 3
    /// Eye is closed when EAR drops below baseline × this ratio.
    public var closedRatio = 0.6
    /// Eye is open again when EAR rises above baseline × this ratio.
    public var reopenRatio = 0.85
    /// Closures longer than this are not counted as blinks.
    public var maxBlinkDuration: TimeInterval = 0.6
    public var requiredBlinks = 1
    /// Head turn (degrees from the resting yaw) required by the challenge.
    public var minYawDelta = 8.0

    public init() {}
}

public enum LivenessState: Sendable, Equatable {
    case inProgress
    case passed
}

/// Minimum liveness: at least one natural blink plus a head turn in the challenged direction.
/// A still photo never passes. Timeouts are enforced by the caller.
public struct LivenessChecker: Sendable {
    public let challenge: LivenessChallenge
    public let config: LivenessConfig

    public private(set) var blinkCount = 0
    public private(set) var challengeCompleted = false

    private var baselineEARs: [Double] = []
    private var baselineYaws: [Double] = []
    private var openEAR: Double?
    private var restingYaw: Double?
    private var eyesClosedSince: TimeInterval?

    public init(challenge: LivenessChallenge, config: LivenessConfig = LivenessConfig()) {
        self.challenge = challenge
        self.config = config
    }

    public var state: LivenessState {
        blinkCount >= config.requiredBlinks && challengeCompleted ? .passed : .inProgress
    }

    @discardableResult
    public mutating func add(_ sample: LivenessSample) -> LivenessState {
        let ear = (sample.leftEyeAspectRatio + sample.rightEyeAspectRatio) / 2
        guard ear.isFinite, sample.yawDegrees.isFinite else { return state }

        guard let open = openEAR, let resting = restingYaw else {
            baselineEARs.append(ear)
            baselineYaws.append(sample.yawDegrees)
            if baselineEARs.count >= config.baselineSamples {
                openEAR = baselineEARs.reduce(0, +) / Double(baselineEARs.count)
                restingYaw = baselineYaws.reduce(0, +) / Double(baselineYaws.count)
            }
            return state
        }

        updateBlink(ear: ear, open: open, at: sample.timestamp)

        if (sample.yawDegrees - resting) * challenge.yawSign >= config.minYawDelta {
            challengeCompleted = true
        }
        return state
    }

    private mutating func updateBlink(ear: Double, open: Double, at time: TimeInterval) {
        if let closedSince = eyesClosedSince {
            guard ear >= open * config.reopenRatio else { return }
            if time - closedSince <= config.maxBlinkDuration {
                blinkCount += 1
            }
            eyesClosedSince = nil
        } else if ear < open * config.closedRatio {
            eyesClosedSince = time
        } else if ear >= open * config.reopenRatio {
            // Track slow changes in the open-eye baseline (lighting, distance).
            openEAR = open * 0.9 + ear * 0.1
        }
    }
}
