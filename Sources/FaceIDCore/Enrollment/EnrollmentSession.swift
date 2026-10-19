import Foundation

public enum EnrollmentPose: String, CaseIterable, Sendable {
    case front, left, right, up, down

    /// Thai prompt for the menu bar app.
    public var instruction: String {
        switch self {
        case .front: "มองตรงมาที่กล้อง"
        case .left: "หันหน้าไปทางซ้ายเล็กน้อย"
        case .right: "หันหน้าไปทางขวาเล็กน้อย"
        case .up: "เงยหน้าขึ้นเล็กน้อย"
        case .down: "ก้มหน้าลงเล็กน้อย"
        }
    }

    /// Classifies a head pose, or nil when it is in between buckets.
    static func classify(yaw: Double, pitch: Double, offset: Double) -> EnrollmentPose? {
        let leftness = yaw * HeadPoseConvention.leftTurnYawSign
        let upness = pitch * HeadPoseConvention.upTiltPitchSign
        let half = offset / 2
        if abs(leftness) < half && abs(upness) < half { return .front }
        if abs(upness) < half {
            if leftness >= offset { return .left }
            if leftness <= -offset { return .right }
        }
        if abs(leftness) < half {
            if upness >= offset { return .up }
            if upness <= -offset { return .down }
        }
        return nil
    }
}

/// Collects embeddings across several head poses. Frontal samples come first and every later
/// sample must resemble them, so a second person cannot be mixed into the template.
///
/// The caller must run liveness during enrollment and must have authenticated the user
/// with their password before saving the resulting template.
public struct EnrollmentSession: Sendable {
    /// Why the last offered sample was not stored (for diagnostics; never shown with face data).
    public enum Rejection: String, Sendable, Equatable {
        case calibrating
        case missingPose
        case ambiguousPose
        case poseAlreadyFull
        case needsFrontFirst
        case notConsistent
    }

    public let samplesPerPose: Int
    public let consistencyThreshold: Float
    public let poseOffsetDegrees: Double
    /// Frames used to learn how this user naturally faces the camera (a laptop camera below eye
    /// level gives ~10–15° of pitch when looking "straight"; seen on a MacBook Air).
    public let baselineFrames: Int
    public private(set) var samples: [EnrollmentPose: [FaceEmbedding]] = [:]
    public private(set) var baseline: (yaw: Double, pitch: Double)?
    public private(set) var lastRejection: Rejection?
    private var baselineSamples: [(yaw: Double, pitch: Double)] = []

    public init(
        samplesPerPose: Int = FaceIDConfig.enrollmentSamples / EnrollmentPose.allCases.count,
        consistencyThreshold: Float = FaceIDConfig.enrollmentConsistencyThreshold,
        poseOffsetDegrees: Double = 10,
        baselineFrames: Int = 10
    ) {
        self.samplesPerPose = max(1, samplesPerPose)
        self.consistencyThreshold = consistencyThreshold
        self.poseOffsetDegrees = poseOffsetDegrees
        self.baselineFrames = max(0, baselineFrames)
        if self.baselineFrames == 0 {
            baseline = (0, 0)
        }
    }

    public var nextPose: EnrollmentPose? {
        EnrollmentPose.allCases.first { (samples[$0]?.count ?? 0) < samplesPerPose }
    }

    public var isComplete: Bool { nextPose == nil }

    public var progress: Double {
        let collected = EnrollmentPose.allCases.reduce(0) { $0 + min(samplesPerPose, samples[$1]?.count ?? 0) }
        return Double(collected) / Double(samplesPerPose * EnrollmentPose.allCases.count)
    }

    /// Offers one quality-checked sample. Returns the pose it was stored under, or nil if rejected
    /// (see `lastRejection`). The first `baselineFrames` samples only calibrate the natural pose.
    @discardableResult
    public mutating func consider(face: FaceObservation, embedding: FaceEmbedding) -> EnrollmentPose? {
        guard let yaw = face.yawDegrees, let pitch = face.pitchDegrees, yaw.isFinite, pitch.isFinite else {
            return reject(.missingPose)
        }
        guard let baseline else {
            baselineSamples.append((yaw, pitch))
            if baselineSamples.count >= baselineFrames {
                baseline = (Self.median(baselineSamples.map(\.yaw)), Self.median(baselineSamples.map(\.pitch)))
            }
            return reject(.calibrating)
        }
        guard let pose = EnrollmentPose.classify(yaw: yaw - baseline.yaw, pitch: pitch - baseline.pitch, offset: poseOffsetDegrees) else {
            return reject(.ambiguousPose)
        }
        guard (samples[pose]?.count ?? 0) < samplesPerPose else { return reject(.poseAlreadyFull) }

        let frontal = samples[.front] ?? []
        if pose != .front && frontal.isEmpty {
            return reject(.needsFrontFirst)
        }
        if !frontal.isEmpty {
            guard let similarity = Matcher().bestSimilarity(embedding, templates: frontal),
                  similarity >= consistencyThreshold
            else { return reject(.notConsistent) }
        }

        lastRejection = nil
        samples[pose, default: []].append(embedding)
        return pose
    }

    public func makeTemplate(modelIdentifier: String) throws -> EnrolledTemplate {
        guard isComplete else { throw FaceIDError.enrollmentIncomplete }
        let embeddings = EnrollmentPose.allCases.flatMap { samples[$0] ?? [] }
        return EnrolledTemplate(modelIdentifier: modelIdentifier, embeddings: embeddings)
    }

    private mutating func reject(_ reason: Rejection) -> EnrollmentPose? {
        lastRejection = reason
        return nil
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
