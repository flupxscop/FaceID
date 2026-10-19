import CoreGraphics
import Testing
@testable import FaceIDCore

struct QualityGateTests {
    private let gate = QualityGate()

    private func face(
        width: CGFloat = 0.4,
        yaw: Double? = 0,
        pitch: Double? = 0,
        roll: Double? = 0,
        quality: Float? = 0.8,
        alignment: [CGPoint]? = sampleAlignmentPoints
    ) -> FaceObservation {
        FaceObservation(
            boundingBox: CGRect(x: 0.3, y: 0.3, width: width, height: width),
            rollDegrees: roll,
            yawDegrees: yaw,
            pitchDegrees: pitch,
            captureQuality: quality,
            landmarks: FaceLandmarks(leftEye: eye(ear: 0.3), rightEye: eye(ear: 0.3), alignmentPoints: alignment)
        )
    }

    private func analysis(
        _ faces: [FaceObservation],
        metrics: ImageMetrics? = ImageMetrics(brightness: 0.5, sharpness: 100)
    ) -> FrameAnalysis {
        FrameAnalysis(timestamp: 0, faces: faces, metrics: metrics)
    }

    @Test func goodFramePasses() {
        #expect(gate.evaluate(analysis([face()])) == nil)
    }

    @Test func noFace() {
        #expect(gate.evaluate(analysis([])) == .noFace)
    }

    @Test func multipleFacesAreRejected() {
        #expect(gate.evaluate(analysis([face(), face()])) == .multipleFaces)
    }

    @Test func smallFace() {
        #expect(gate.evaluate(analysis([face(width: 0.1)])) == .faceTooSmall)
    }

    @Test(arguments: [(45.0, 0.0, 0.0), (0, 40, 0), (0, 0, 40), (.nan, 0, 0)])
    func badPose(yaw: Double, pitch: Double, roll: Double) {
        #expect(gate.evaluate(analysis([face(yaw: yaw, pitch: pitch, roll: roll)])) == .badPose)
    }

    @Test func missingPoseAnglesAreNotTreatedAsBadPose() {
        #expect(gate.evaluate(analysis([face(yaw: nil, pitch: nil, roll: nil)])) == nil)
    }

    @Test func missingAlignmentPointsAreRejected() {
        #expect(gate.evaluate(analysis([face(alignment: nil)])) == .missingLandmarks)
        #expect(gate.evaluate(analysis([face(alignment: Array(sampleAlignmentPoints.prefix(3)))])) == .missingLandmarks)
    }

    @Test func lowCaptureQuality() {
        #expect(gate.evaluate(analysis([face(quality: 0.39)])) == .lowCaptureQuality)
    }

    @Test func captureQualityAtMinimumPasses() {
        #expect(gate.evaluate(analysis([face(quality: FaceIDConfig.minFaceCaptureQuality)])) == nil)
    }

    @Test func missingCaptureQualityFailsClosed() {
        #expect(gate.evaluate(analysis([face(quality: nil)])) == .lowCaptureQuality)
    }

    @Test func missingMetricsFailClosed() {
        #expect(gate.evaluate(analysis([face()], metrics: nil)) == .unmeasurable)
    }

    @Test func lighting() {
        #expect(gate.evaluate(analysis([face()], metrics: ImageMetrics(brightness: 0.05, sharpness: 100))) == .tooDark)
        #expect(gate.evaluate(analysis([face()], metrics: ImageMetrics(brightness: 0.98, sharpness: 100))) == .tooBright)
    }

    @Test func blur() {
        #expect(gate.evaluate(analysis([face()], metrics: ImageMetrics(brightness: 0.5, sharpness: 2))) == .blurry)
    }
}

struct ImageMetricsCalculatorTests {
    @Test func uniformImageHasNoSharpness() throws {
        let metrics = try #require(ImageMetricsCalculator.measure(
            width: 64, height: 64, region: CGRect(x: 0, y: 0, width: 64, height: 64)
        ) { _, _ in 128 })
        #expect(metrics.sharpness == 0)
        #expect(abs(metrics.brightness - 128.0 / 255) < 1e-9)
    }

    @Test func checkerboardIsSharp() throws {
        let metrics = try #require(ImageMetricsCalculator.measure(
            width: 64, height: 64, region: CGRect(x: 0, y: 0, width: 64, height: 64)
        ) { x, y in (x + y) % 2 == 0 ? 255 : 0 })
        #expect(metrics.sharpness > 1000)
    }

    @Test func regionOutsideImageReturnsNil() {
        let metrics = ImageMetricsCalculator.measure(
            width: 64, height: 64, region: CGRect(x: 100, y: 100, width: 10, height: 10)
        ) { _, _ in 0 }
        #expect(metrics == nil)
    }
}
