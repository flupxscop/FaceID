import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Vision-based face analysis: rectangles + pose, landmarks, capture quality and image metrics.
public actor FaceDetector: FaceAnalyzing {
    public init() {}

    public func analyze(_ frame: CameraFrame) async throws -> FrameAnalysis {
        let pixelBuffer = frame.pixelBuffer
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        let rectangles = VNDetectFaceRectanglesRequest()
        rectangles.revision = VNDetectFaceRectanglesRequestRevision3   // adds pitch
        do {
            try handler.perform([rectangles])
        } catch {
            throw FaceIDError.detectionFailed
        }
        let detected = rectangles.results ?? []
        guard !detected.isEmpty else {
            return FrameAnalysis(timestamp: frame.timestamp, faces: [], metrics: nil)
        }

        let landmarksRequest = VNDetectFaceLandmarksRequest()
        landmarksRequest.inputFaceObservations = detected
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        qualityRequest.inputFaceObservations = detected
        // Landmarks/quality are optional per face; a failure here just leaves them nil (and fails the quality gate).
        try? handler.perform([landmarksRequest, qualityRequest])

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let imageSize = CGSize(width: width, height: height)
        let landmarkResults = landmarksRequest.results ?? []
        let qualityResults = qualityRequest.results ?? []

        let faces = detected.enumerated().map { index, rect -> FaceObservation in
            let landmarks = landmarkResults.indices.contains(index) ? landmarkResults[index].landmarks : nil
            let quality: Float? = qualityResults.indices.contains(index) ? qualityResults[index].faceCaptureQuality : nil
            return FaceObservation(
                boundingBox: rect.boundingBox,
                rollDegrees: rect.roll.map { Self.degrees($0) },
                yawDegrees: rect.yaw.map { Self.degrees($0) },
                pitchDegrees: rect.pitch.map { Self.degrees($0) },
                captureQuality: quality,
                landmarks: landmarks.flatMap { Self.eyes(from: $0, imageSize: imageSize) }
            )
        }

        let primary = faces.max { Self.area($0) < Self.area($1) }
        let metrics = primary.flatMap { Self.metrics(for: $0, pixelBuffer: pixelBuffer) }
        return FrameAnalysis(timestamp: frame.timestamp, faces: faces, metrics: metrics)
    }

    private static func area(_ face: FaceObservation) -> CGFloat {
        face.boundingBox.width * face.boundingBox.height
    }

    private static func degrees(_ radians: NSNumber) -> Double {
        radians.doubleValue * 180 / .pi
    }

    private static func eyes(from landmarks: VNFaceLandmarks2D, imageSize: CGSize) -> FaceLandmarks? {
        guard let left = landmarks.leftEye?.pointsInImage(imageSize: imageSize),
              let right = landmarks.rightEye?.pointsInImage(imageSize: imageSize)
        else { return nil }
        return FaceLandmarks(leftEye: left, rightEye: right, alignmentPoints: alignmentPoints(from: landmarks, imageSize: imageSize))
    }

    /// The 5 alignment points in top-left-origin pixels (Vision reports a bottom-left origin).
    private static func alignmentPoints(from landmarks: VNFaceLandmarks2D, imageSize: CGSize) -> [CGPoint]? {
        func topLeft(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (region?.pointsInImage(imageSize: imageSize) ?? []).map { CGPoint(x: $0.x, y: imageSize.height - $0.y) }
        }
        return FaceAlignment.fivePoints(
            leftEye: topLeft(landmarks.leftEye),
            rightEye: topLeft(landmarks.rightEye),
            leftPupil: topLeft(landmarks.leftPupil).first,
            rightPupil: topLeft(landmarks.rightPupil).first,
            noseCrest: topLeft(landmarks.noseCrest),
            nose: topLeft(landmarks.nose),
            outerLips: topLeft(landmarks.outerLips)
        )
    }

    private static func metrics(for face: FaceObservation, pixelBuffer: CVPixelBuffer) -> ImageMetrics? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        // Vision rects have a bottom-left origin; pixel rows start at the top.
        let rect = VNImageRectForNormalizedRect(face.boundingBox, width, height)
        let region = CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)

        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let luma = base.assumingMemoryBound(to: UInt8.self)
            return ImageMetricsCalculator.measure(width: width, height: height, region: region) { x, y in
                luma[y * rowBytes + x]
            }
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            return ImageMetricsCalculator.measure(width: width, height: height, region: region) { x, y in
                let offset = y * rowBytes + x * 4
                let luma = 0.114 * Double(pixels[offset]) + 0.587 * Double(pixels[offset + 1]) + 0.299 * Double(pixels[offset + 2])
                return UInt8(min(255, luma))
            }
        default:
            return nil
        }
    }
}
