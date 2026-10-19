import CoreGraphics
import Testing
@testable import FaceIDCore

struct EyeAspectRatioTests {
    @Test func openEye() throws {
        let ear = try #require(EyeAspectRatio.compute(eye(ear: 0.3)))
        #expect(abs(ear - 0.3) < 1e-9)
    }

    @Test func isRollInvariant() throws {
        let angle = 0.5
        let rotated = eye(ear: 0.3).map {
            CGPoint(x: $0.x * cos(angle) - $0.y * sin(angle), y: $0.x * sin(angle) + $0.y * cos(angle))
        }
        let ear = try #require(EyeAspectRatio.compute(rotated))
        #expect(abs(ear - 0.3) < 1e-9)
    }

    @Test func tooFewPoints() {
        #expect(EyeAspectRatio.compute([.zero, CGPoint(x: 1, y: 0)]) == nil)
    }

    @Test func degeneratePoints() {
        #expect(EyeAspectRatio.compute(Array(repeating: .zero, count: 6)) == nil)
    }
}

struct LivenessCheckerTests {
    private let left = HeadPoseConvention.leftTurnYawSign

    private func run(_ challenge: LivenessChallenge, _ frames: [(ear: Double, yaw: Double)]) -> LivenessChecker {
        var checker = LivenessChecker(challenge: challenge)
        for (i, frame) in frames.enumerated() {
            checker.add(LivenessSample(
                timestamp: Double(i) / 30,
                leftEyeAspectRatio: frame.ear,
                rightEyeAspectRatio: frame.ear,
                yawDegrees: frame.yaw
            ))
        }
        return checker
    }

    private func open(_ count: Int, yaw: Double = 0) -> [(ear: Double, yaw: Double)] {
        Array(repeating: (0.3, yaw), count: count)
    }

    private func closed(_ count: Int) -> [(ear: Double, yaw: Double)] {
        Array(repeating: (0.05, 0), count: count)
    }

    @Test func stillPhotoNeverPasses() {
        let checker = run(.turnLeft, open(300))
        #expect(checker.state == .inProgress)
        #expect(checker.blinkCount == 0)
        #expect(!checker.challengeCompleted)
    }

    @Test func blinkAndCorrectTurnPasses() {
        let checker = run(.turnLeft, open(5) + closed(3) + open(3) + open(5, yaw: 12 * left))
        #expect(checker.blinkCount == 1)
        #expect(checker.state == .passed)
    }

    @Test func turnBeforeBlinkAlsoPasses() {
        let checker = run(.turnRight, open(5) + open(5, yaw: -12 * left) + open(3) + closed(3) + open(3))
        #expect(checker.state == .passed)
    }

    @Test func blinkWithoutTurnFails() {
        #expect(run(.turnLeft, open(5) + closed(3) + open(30)).state == .inProgress)
    }

    @Test func turnWithoutBlinkFails() {
        // e.g. a printed photo being rotated
        #expect(run(.turnLeft, open(5) + open(30, yaw: 15 * left)).state == .inProgress)
    }

    @Test func wrongDirectionFails() {
        let checker = run(.turnLeft, open(5) + closed(3) + open(3) + open(10, yaw: -15 * left))
        #expect(checker.blinkCount == 1)
        #expect(!checker.challengeCompleted)
        #expect(checker.state == .inProgress)
    }

    @Test func smallTurnIsNotEnough() {
        #expect(run(.turnLeft, open(5) + closed(3) + open(10, yaw: 5 * left)).state == .inProgress)
    }

    @Test func longEyeClosureIsNotABlink() {
        // 1 second closed > maxBlinkDuration
        let checker = run(.turnLeft, open(5) + closed(30) + open(5, yaw: 12 * left))
        #expect(checker.blinkCount == 0)
        #expect(checker.state == .inProgress)
    }

    @Test func nonFiniteSamplesAreIgnored() {
        let checker = run(.turnLeft, open(5) + [(.nan, 0), (0.3, .infinity)] + open(5))
        #expect(checker.state == .inProgress)
    }

    @Test func sampleFromFaceObservation() throws {
        let face = FaceObservation(
            boundingBox: .zero,
            yawDegrees: 3,
            landmarks: FaceLandmarks(leftEye: eye(ear: 0.3), rightEye: eye(ear: 0.2))
        )
        let sample = try #require(LivenessSample(face: face, timestamp: 1))
        #expect(abs(sample.leftEyeAspectRatio - 0.3) < 1e-9)
        #expect(abs(sample.rightEyeAspectRatio - 0.2) < 1e-9)
        #expect(sample.yawDegrees == 3)
    }

    @Test func sampleRequiresLandmarksAndYaw() {
        #expect(LivenessSample(face: FaceObservation(boundingBox: .zero, yawDegrees: 0), timestamp: 0) == nil)
        let noYaw = FaceObservation(boundingBox: .zero, landmarks: FaceLandmarks(leftEye: eye(ear: 0.3), rightEye: eye(ear: 0.3)))
        #expect(LivenessSample(face: noYaw, timestamp: 0) == nil)
    }
}
