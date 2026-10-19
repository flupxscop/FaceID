import CoreGraphics
import Testing
@testable import FaceIDCore

struct EnrollmentSessionTests {
    private func face(_ pose: EnrollmentPose) -> FaceObservation {
        let yaw = 15 * HeadPoseConvention.leftTurnYawSign
        let pitch = 15 * HeadPoseConvention.upTiltPitchSign
        let angles: (Double, Double) = switch pose {
        case .front: (0, 0)
        case .left: (yaw, 0)
        case .right: (-yaw, 0)
        case .up: (0, pitch)
        case .down: (0, -pitch)
        }
        return FaceObservation(boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), yawDegrees: angles.0, pitchDegrees: angles.1)
    }

    @Test func collectsAllPosesIntoTemplate() throws {
        var session = EnrollmentSession(baselineFrames: 0)
        for pose in EnrollmentPose.allCases {
            for _ in 0..<session.samplesPerPose {
                let accepted = session.consider(face: face(pose), embedding: ownerEmbedding)
                #expect(accepted == pose)
            }
        }
        #expect(session.isComplete)
        #expect(session.progress == 1)
        let template = try session.makeTemplate(modelIdentifier: testModelID)
        #expect(template.embeddings.count == FaceIDConfig.enrollmentSamples)
    }

    @Test func sideViewsRequireFrontalSamplesFirst() {
        var session = EnrollmentSession(baselineFrames: 0)
        let accepted = session.consider(face: face(.left), embedding: ownerEmbedding)
        #expect(accepted == nil)
        #expect(session.nextPose == .front)
    }

    @Test func differentPersonIsRejected() {
        var session = EnrollmentSession(baselineFrames: 0)
        session.consider(face: face(.front), embedding: ownerEmbedding)
        let front = session.consider(face: face(.front), embedding: strangerEmbedding)
        let side = session.consider(face: face(.left), embedding: strangerEmbedding)
        #expect(front == nil)
        #expect(side == nil)
    }

    @Test func fullPoseBucketRejectsExtraSamples() {
        var session = EnrollmentSession(samplesPerPose: 1, baselineFrames: 0)
        session.consider(face: face(.front), embedding: ownerEmbedding)
        let accepted = session.consider(face: face(.front), embedding: ownerEmbedding)
        #expect(accepted == nil)
    }

    @Test func ambiguousPoseIsRejected() {
        var session = EnrollmentSession(baselineFrames: 0)
        let diagonal = FaceObservation(boundingBox: .zero, yawDegrees: 15, pitchDegrees: 15)
        let accepted = session.consider(face: diagonal, embedding: ownerEmbedding)
        #expect(accepted == nil)
    }

    @Test func incompleteEnrollmentCannotProduceTemplate() {
        var session = EnrollmentSession(baselineFrames: 0)
        session.consider(face: face(.front), embedding: ownerEmbedding)
        #expect(throws: FaceIDError.enrollmentIncomplete) { try session.makeTemplate(modelIdentifier: testModelID) }
    }

    @Test func posesAreMeasuredFromTheNaturalHeadPose() {
        // A laptop camera below eye level: looking "straight" reads as ~12° pitch.
        var session = EnrollmentSession(baselineFrames: 3)
        let natural = FaceObservation(boundingBox: .zero, yawDegrees: 1, pitchDegrees: 12)
        for _ in 0..<3 {
            let calibrating = session.consider(face: natural, embedding: ownerEmbedding)
            #expect(calibrating == nil)
            #expect(session.lastRejection == .calibrating)
        }
        #expect(session.baseline?.pitch == 12)

        let front = session.consider(face: natural, embedding: ownerEmbedding)
        #expect(front == .front, "the natural pose counts as front, not as looking down")

        let up = 12 + 11 * HeadPoseConvention.upTiltPitchSign
        let tilted = session.consider(face: FaceObservation(boundingBox: .zero, yawDegrees: 1, pitchDegrees: up), embedding: ownerEmbedding)
        #expect(tilted == .up)
    }

    @Test func baselineIsTheMedian() {
        var session = EnrollmentSession(baselineFrames: 3)
        for pitch in [10.0, 30.0, 12.0] {
            session.consider(face: FaceObservation(boundingBox: .zero, yawDegrees: 0, pitchDegrees: pitch), embedding: ownerEmbedding)
        }
        #expect(session.baseline?.pitch == 12, "one stray frame does not shift the baseline")
    }

    @Test func rejectionReasonsAreReported() {
        var session = EnrollmentSession(samplesPerPose: 1, baselineFrames: 0)
        session.consider(face: FaceObservation(boundingBox: .zero), embedding: ownerEmbedding)
        #expect(session.lastRejection == .missingPose)
        session.consider(face: face(.left), embedding: ownerEmbedding)
        #expect(session.lastRejection == .needsFrontFirst)
        session.consider(face: FaceObservation(boundingBox: .zero, yawDegrees: 15, pitchDegrees: 15), embedding: ownerEmbedding)
        #expect(session.lastRejection == .ambiguousPose)
        session.consider(face: face(.front), embedding: ownerEmbedding)
        #expect(session.lastRejection == nil)
        session.consider(face: face(.front), embedding: ownerEmbedding)
        #expect(session.lastRejection == .poseAlreadyFull)
        session.consider(face: face(.left), embedding: strangerEmbedding)
        #expect(session.lastRejection == .notConsistent)
    }

    @Test func instructionsExistForEveryPose() {
        for pose in EnrollmentPose.allCases {
            #expect(!pose.instruction.isEmpty)
        }
    }
}
