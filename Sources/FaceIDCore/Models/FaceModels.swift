import CoreGraphics
import CoreVideo
import Foundation

/// A single camera frame. Lives in memory only — frames must never be written to disk.
public struct CameraFrame: @unchecked Sendable {
    // CVPixelBuffer is not Sendable; frames are produced once and only read afterwards.
    public let pixelBuffer: CVPixelBuffer
    public let timestamp: TimeInterval
    public let sequenceNumber: Int

    public init(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval, sequenceNumber: Int) {
        self.pixelBuffer = pixelBuffer
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
    }
}

public struct FaceEmbedding: Codable, Sendable, Equatable {
    public let vector: [Float]

    public init(_ vector: [Float]) {
        self.vector = vector
    }

    public var dimension: Int { vector.count }
}

public struct FaceLandmarks: Sendable, Equatable {
    /// Eye contour points in image coordinates (any origin; only ratios are used).
    public var leftEye: [CGPoint]
    public var rightEye: [CGPoint]
    /// The 5 points for `FaceAlignment` (pixels, top-left origin, ordered like
    /// `FaceAlignment.referencePoints`). nil when Vision did not provide enough landmarks.
    public var alignmentPoints: [CGPoint]?

    public init(leftEye: [CGPoint], rightEye: [CGPoint], alignmentPoints: [CGPoint]? = nil) {
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.alignmentPoints = alignmentPoints
    }
}

public struct FaceObservation: Sendable, Equatable {
    /// Normalized bounding box in Vision coordinates (origin bottom-left).
    public var boundingBox: CGRect
    public var rollDegrees: Double?
    public var yawDegrees: Double?
    public var pitchDegrees: Double?
    public var captureQuality: Float?
    public var landmarks: FaceLandmarks?

    public init(
        boundingBox: CGRect,
        rollDegrees: Double? = nil,
        yawDegrees: Double? = nil,
        pitchDegrees: Double? = nil,
        captureQuality: Float? = nil,
        landmarks: FaceLandmarks? = nil
    ) {
        self.boundingBox = boundingBox
        self.rollDegrees = rollDegrees
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
        self.captureQuality = captureQuality
        self.landmarks = landmarks
    }
}

public struct ImageMetrics: Sendable, Equatable {
    /// Mean luma of the face region, 0...1.
    public var brightness: Double
    /// Variance of the Laplacian on 0...255 luma; higher is sharper.
    public var sharpness: Double

    public init(brightness: Double, sharpness: Double) {
        self.brightness = brightness
        self.sharpness = sharpness
    }
}

public struct FrameAnalysis: Sendable, Equatable {
    public var timestamp: TimeInterval
    public var faces: [FaceObservation]
    /// Measured on the largest face's region; nil when it could not be measured.
    public var metrics: ImageMetrics?

    public init(timestamp: TimeInterval, faces: [FaceObservation], metrics: ImageMetrics?) {
        self.timestamp = timestamp
        self.faces = faces
        self.metrics = metrics
    }
}
