import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// 5-point face alignment, matching OpenCV's `FaceRecognizerSF::alignCrop` which the SFace model
/// was trained with: a similarity transform (rotation + uniform scale + translation) of the face's
/// eyes, nose tip and mouth corners onto fixed reference points in a 112x112 crop.
///
/// All points are image pixels with a **top-left origin**, like OpenCV.
public enum FaceAlignment {
    public static let outputSize = 112

    /// OpenCV's reference points, ordered by image x: eye, eye, nose tip, mouth corner, mouth corner.
    public static let referencePoints: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]

    // MARK: - Transform

    /// Least-squares similarity transform mapping `source` onto `destination`, without reflection.
    /// Same optimum as the Umeyama method OpenCV uses (for proper rotations).
    /// nil when the points are degenerate or the counts differ.
    public static func similarityTransform(from source: [CGPoint], to destination: [CGPoint]) -> CGAffineTransform? {
        guard source.count == destination.count, source.count >= 2 else { return nil }
        let n = Double(source.count)
        let sourceMean = mean(source)
        let destinationMean = mean(destination)

        var dot = 0.0, cross = 0.0, sourceVariance = 0.0
        for (s, d) in zip(source, destination) {
            let sx = Double(s.x - sourceMean.x), sy = Double(s.y - sourceMean.y)
            let dx = Double(d.x - destinationMean.x), dy = Double(d.y - destinationMean.y)
            dot += sx * dx + sy * dy
            cross += sx * dy - sy * dx
            sourceVariance += sx * sx + sy * sy
        }
        guard sourceVariance / n > 1e-9 else { return nil }

        // x' = a·x − b·y + tx,  y' = b·x + a·y + ty   (a = s·cosθ, b = s·sinθ)
        let a = dot / sourceVariance
        let b = cross / sourceVariance
        let tx = Double(destinationMean.x) - (a * Double(sourceMean.x) - b * Double(sourceMean.y))
        let ty = Double(destinationMean.y) - (b * Double(sourceMean.x) + a * Double(sourceMean.y))
        guard [a, b, tx, ty].allSatisfy(\.isFinite), a * a + b * b > 1e-12 else { return nil }
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }

    // MARK: - Landmarks → 5 points

    /// The 5 alignment points from Vision-style landmark regions (top-left origin pixels), ordered
    /// like `referencePoints` — by image x, so a mirrored camera and left/right naming do not matter.
    ///
    /// - eye centre: the pupil when available, otherwise the mean of the eye contour;
    /// - nose tip: the nose-crest point farthest from the midpoint between the eyes
    ///   (the centroid of the nose region when there is no crest);
    /// - mouth corners: the two outer-lip points farthest apart.
    public static func fivePoints(
        leftEye: [CGPoint],
        rightEye: [CGPoint],
        leftPupil: CGPoint? = nil,
        rightPupil: CGPoint? = nil,
        noseCrest: [CGPoint],
        nose: [CGPoint],
        outerLips: [CGPoint]
    ) -> [CGPoint]? {
        guard !leftEye.isEmpty, !rightEye.isEmpty, outerLips.count >= 2 else { return nil }
        let eyeA = leftPupil ?? mean(leftEye)
        let eyeB = rightPupil ?? mean(rightEye)
        let eyesMid = CGPoint(x: (eyeA.x + eyeB.x) / 2, y: (eyeA.y + eyeB.y) / 2)

        let noseTip: CGPoint
        if let farthest = noseCrest.max(by: { distance($0, eyesMid) < distance($1, eyesMid) }) {
            noseTip = farthest
        } else if !nose.isEmpty {
            noseTip = mean(nose)
        } else {
            return nil
        }

        guard let corners = farthestPair(outerLips) else { return nil }
        let eyes = [eyeA, eyeB].sorted { $0.x < $1.x }
        let mouth = [corners.0, corners.1].sorted { $0.x < $1.x }
        let points = [eyes[0], eyes[1], noseTip, mouth[0], mouth[1]]
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        return points
    }

    // MARK: - Warp

    /// Renders the aligned 112x112 face as a 32BGRA pixel buffer. Areas outside the source image are
    /// black, like OpenCV's `warpAffine`. Colour management is off so pixel values stay unchanged.
    public static func alignedFace(
        from pixelBuffer: CVPixelBuffer,
        points: [CGPoint],
        context: CIContext = FaceAlignment.makeContext()
    ) throws -> CVPixelBuffer {
        guard points.count == referencePoints.count,
              let transform = similarityTransform(from: points, to: referencePoints)
        else { throw FaceIDError.embeddingFailed }

        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let size = CGFloat(outputSize)
        // Core Image uses a bottom-left origin for both images: flip in, align, flip out.
        let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        let flipOutput = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size)
        let ciTransform = flipSource.concatenating(transform).concatenating(flipOutput)
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let aligned = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: ciTransform)
            .composited(over: CIImage(color: .black).cropped(to: bounds))
            .cropped(to: bounds)

        var output: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        CVPixelBufferCreate(kCFAllocatorDefault, outputSize, outputSize, kCVPixelFormatType_32BGRA,
                            attributes as CFDictionary, &output)
        guard let output else { throw FaceIDError.embeddingFailed }
        context.render(aligned, to: output, bounds: bounds, colorSpace: nil)
        return output
    }

    /// A context without colour management, so model inputs keep their original pixel values.
    public static func makeContext() -> CIContext {
        CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    }

    // MARK: - Helpers

    static func mean(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    static func farthestPair(_ points: [CGPoint]) -> (CGPoint, CGPoint)? {
        guard points.count >= 2 else { return nil }
        var best = (points[0], points[1])
        var bestDistance = -1.0
        for i in points.indices {
            for j in points.indices where j > i {
                let d = Double(distance(points[i], points[j]))
                if d > bestDistance {
                    bestDistance = d
                    best = (points[i], points[j])
                }
            }
        }
        return bestDistance > 0 ? best : nil
    }
}
