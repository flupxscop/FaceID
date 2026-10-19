import CoreGraphics
import CoreVideo
import Foundation
@testable import FaceIDCore

final class InMemoryItemStorage: SecureItemStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func read(account: String) throws -> Data? {
        lock.withLock { items[account] }
    }

    func write(_ data: Data, account: String) throws {
        lock.withLock { items[account] = data }
    }

    func delete(account: String) throws {
        lock.withLock { _ = items.removeValue(forKey: account) }
    }
}

final class InMemoryTemplateStore: TemplateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var template: EnrolledTemplate?

    init(_ template: EnrolledTemplate? = nil) {
        self.template = template
    }

    func load() throws -> EnrolledTemplate? { lock.withLock { template } }
    func save(_ template: EnrolledTemplate) throws { lock.withLock { self.template = template } }
    func delete() throws { lock.withLock { template = nil } }
}

func makePixelBuffer() -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
    return buffer!
}

/// Fake camera: emits `frameCount` frames, then either ends or stays open until cancelled.
final class MockCamera: CameraProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let frameCount: Int
    private let keepOpen: Bool
    private let startError: FaceIDError?
    private var _stopCount = 0

    init(frameCount: Int, keepOpen: Bool = true, startError: FaceIDError? = nil) {
        self.frameCount = frameCount
        self.keepOpen = keepOpen
        self.startError = startError
    }

    var stopCount: Int { lock.withLock { _stopCount } }

    func frames() async throws -> AsyncThrowingStream<CameraFrame, Error> {
        if let startError { throw startError }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: CameraFrame.self, throwing: Error.self)
        let buffer = makePixelBuffer()
        for i in 0..<frameCount {
            continuation.yield(CameraFrame(pixelBuffer: buffer, timestamp: Double(i) / 30, sequenceNumber: i))
        }
        if !keepOpen { continuation.finish() }
        return stream
    }

    func stop() async {
        lock.withLock { _stopCount += 1 }
    }
}

struct FrameScript: Sendable {
    var faces = 1
    var ear = 0.3
    var yaw = 0.0
    var pitch = 0.0
    var quality: Float = 0.8
    /// Horizontal position of the face box (normalised), to simulate a different face appearing.
    var x = 0.3
}

/// Returns a scripted analysis per frame sequence number.
struct ScriptedAnalyzer: FaceAnalyzing {
    let script: [FrameScript]

    func analyze(_ frame: CameraFrame) async throws -> FrameAnalysis {
        let step = script[min(frame.sequenceNumber, script.count - 1)]
        let face = FaceObservation(
            boundingBox: CGRect(x: step.x, y: 0.3, width: 0.4, height: 0.4),
            rollDegrees: 0,
            yawDegrees: step.yaw,
            pitchDegrees: step.pitch,
            captureQuality: step.quality,
            landmarks: FaceLandmarks(leftEye: eye(ear: step.ear), rightEye: eye(ear: step.ear), alignmentPoints: sampleAlignmentPoints)
        )
        return FrameAnalysis(
            timestamp: frame.timestamp,
            faces: Array(repeating: face, count: step.faces),
            metrics: ImageMetrics(brightness: 0.5, sharpness: 100)
        )
    }
}

/// Returns a scripted embedding per frame sequence number (last one repeats).
struct SequenceEmbedder: EmbeddingProviding {
    let modelIdentifier: String
    let outputs: [FaceEmbedding]

    func embedding(for frame: CameraFrame, face: FaceObservation) async throws -> FaceEmbedding {
        outputs[min(frame.sequenceNumber, outputs.count - 1)]
    }
}

struct FixedEmbedder: EmbeddingProviding {
    let modelIdentifier: String
    let output: FaceEmbedding

    func embedding(for frame: CameraFrame, face: FaceObservation) async throws -> FaceEmbedding {
        output
    }
}

/// Six-point eye contour with the given aspect ratio (width 10).
func eye(ear: Double) -> [CGPoint] {
    let h = ear * 10 / 2
    return [
        CGPoint(x: 0, y: 0), CGPoint(x: 3, y: h), CGPoint(x: 7, y: h),
        CGPoint(x: 10, y: 0), CGPoint(x: 7, y: -h), CGPoint(x: 3, y: -h),
    ]
}

let ownerEmbedding = FaceEmbedding([1, 0, 0, 0])
let strangerEmbedding = FaceEmbedding([0, 1, 0, 0])
let testModelID = "test-model-v1"

/// Open eyes, a quick blink, then a head turn to the left.
func livePersonScript(turnYaw: Double = 12 * HeadPoseConvention.leftTurnYawSign) -> [FrameScript] {
    var script = Array(repeating: FrameScript(), count: 5)
    script += Array(repeating: FrameScript(ear: 0.05, quality: 0.3), count: 3)
    script += Array(repeating: FrameScript(), count: 3)
    script += (1...6).map { FrameScript(yaw: turnYaw * Double($0) / 6) }
    script += Array(repeating: FrameScript(yaw: turnYaw), count: 5)
    return script
}

struct StubOwnerVerifier: OwnerVerifying {
    let approves: Bool

    func verifyOwner(reason: String) async -> Bool { approves }
}

/// Every enrollment pose, with a blink while looking straight ahead.
func enrollmentScript(blink: Bool = true) -> [FrameScript] {
    let left = 15 * HeadPoseConvention.leftTurnYawSign
    let up = 15 * HeadPoseConvention.upTiltPitchSign
    // 10 frames calibrate the natural pose (EnrollmentSession.baselineFrames), then front samples.
    var script = Array(repeating: FrameScript(), count: 14)
    if blink {
        script += Array(repeating: FrameScript(ear: 0.05, quality: 0.3), count: 3)
        script += Array(repeating: FrameScript(), count: 2)
    }
    script += Array(repeating: FrameScript(yaw: left), count: 3)
    script += Array(repeating: FrameScript(yaw: -left), count: 3)
    script += Array(repeating: FrameScript(pitch: up), count: 3)
    script += Array(repeating: FrameScript(pitch: -up), count: 3)
    return script
}

/// A plausible face in a 640x480 frame: the reference points scaled 2x and moved.
let sampleAlignmentPoints = FaceAlignment.referencePoints.map { CGPoint(x: $0.x * 2 + 250, y: $0.y * 2 + 120) }
