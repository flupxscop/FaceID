import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import FaceIDCore

struct SimilarityTransformTests {
    private let reference = FaceAlignment.referencePoints

    /// rotation θ, uniform scale s, translation t — the kind of motion between a face in a frame and the crop.
    private func similarity(degrees: Double, scale: Double, tx: Double, ty: Double) -> CGAffineTransform {
        let r = degrees * .pi / 180
        let a = scale * cos(r), b = scale * sin(r)
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }

    private func close(_ p: CGPoint, _ q: CGPoint, within tolerance: CGFloat) -> Bool {
        abs(p.x - q.x) <= tolerance && abs(p.y - q.y) <= tolerance
    }

    @Test func referenceMapsOntoItself() throws {
        let t = try #require(FaceAlignment.similarityTransform(from: reference, to: reference))
        #expect(abs(t.a - 1) < 1e-9 && abs(t.b) < 1e-9 && abs(t.tx) < 1e-9 && abs(t.ty) < 1e-9)
    }

    @Test(arguments: [(0.0, 1.0), (20.0, 1.7), (-35.0, 3.2), (180.0, 0.5)])
    func recoversAnExactSimilarity(degrees: Double, scale: Double) throws {
        let known = similarity(degrees: degrees, scale: scale, tx: 140, ty: -60)
        let face = reference.map { $0.applying(known) }
        let t = try #require(FaceAlignment.similarityTransform(from: face, to: reference))
        for (point, target) in zip(face, reference) {
            #expect(close(point.applying(t), target, within: 1e-6))
        }
    }

    @Test func noisyLandmarksStayClose() throws {
        let known = similarity(degrees: 12, scale: 2.2, tx: 200, ty: 90)
        let jitter: [CGPoint] = [.init(x: 0.8, y: -0.5), .init(x: -0.6, y: 0.4), .init(x: 0.3, y: 0.9), .init(x: -0.7, y: -0.2), .init(x: 0.4, y: 0.6)]
        let face = zip(reference, jitter).map { CGPoint(x: $0.applying(known).x + $1.x, y: $0.applying(known).y + $1.y) }
        let t = try #require(FaceAlignment.similarityTransform(from: face, to: reference))
        for (point, target) in zip(face, reference) {
            #expect(close(point.applying(t), target, within: 1.0))
        }
    }

    @Test func neverMirrors() throws {
        // A mirrored face still gets a proper rotation (positive determinant), like OpenCV.
        let mirrored = reference.map { CGPoint(x: 300 - $0.x, y: $0.y) }
        let t = try #require(FaceAlignment.similarityTransform(from: mirrored, to: reference))
        #expect(t.a * t.d - t.b * t.c > 0)
    }

    @Test func degenerateInputIsRejected() {
        let same = Array(repeating: CGPoint(x: 10, y: 10), count: 5)
        #expect(FaceAlignment.similarityTransform(from: same, to: reference) == nil)
        #expect(FaceAlignment.similarityTransform(from: Array(reference.prefix(4)), to: reference) == nil)
        #expect(FaceAlignment.similarityTransform(from: [], to: []) == nil)
    }
}

struct FivePointTests {
    private func ring(_ center: CGPoint, rx: CGFloat, ry: CGFloat, count: Int = 8) -> [CGPoint] {
        (0..<count).map { i in
            let angle = Double(i) / Double(count) * 2 * .pi
            return CGPoint(x: center.x + rx * cos(angle), y: center.y + ry * sin(angle))
        }
    }

    private let eyeA = CGPoint(x: 300, y: 200)
    private let eyeB = CGPoint(x: 380, y: 202)
    private let crest = [CGPoint(x: 340, y: 205), CGPoint(x: 341, y: 230), CGPoint(x: 342, y: 255)]

    @Test func extractsOrderedPoints() throws {
        let points = try #require(FaceAlignment.fivePoints(
            leftEye: ring(eyeB, rx: 12, ry: 4),
            rightEye: ring(eyeA, rx: 12, ry: 4),
            noseCrest: crest,
            nose: [],
            outerLips: ring(CGPoint(x: 340, y: 300), rx: 40, ry: 10)
        ))
        #expect(points.count == 5)
        #expect(abs(points[0].x - eyeA.x) < 1e-6 && abs(points[1].x - eyeB.x) < 1e-6, "eyes sorted by image x")
        #expect(points[2] == CGPoint(x: 342, y: 255), "nose tip is the crest point farthest from the eyes")
        #expect(abs(points[3].x - 300) < 1e-6 && abs(points[4].x - 380) < 1e-6, "mouth corners sorted by image x")
    }

    @Test func leftRightNamingDoesNotMatter() throws {
        let lips = ring(CGPoint(x: 340, y: 300), rx: 40, ry: 10)
        let a = FaceAlignment.fivePoints(leftEye: ring(eyeA, rx: 12, ry: 4), rightEye: ring(eyeB, rx: 12, ry: 4),
                                         noseCrest: crest, nose: [], outerLips: lips)
        let b = FaceAlignment.fivePoints(leftEye: ring(eyeB, rx: 12, ry: 4), rightEye: ring(eyeA, rx: 12, ry: 4),
                                         noseCrest: crest, nose: [], outerLips: lips)
        #expect(a != nil)
        #expect(a == b)
    }

    @Test func prefersPupils() throws {
        let pupil = CGPoint(x: 303, y: 199)
        let points = try #require(FaceAlignment.fivePoints(
            leftEye: ring(eyeA, rx: 12, ry: 4), rightEye: ring(eyeB, rx: 12, ry: 4),
            leftPupil: pupil, rightPupil: eyeB,
            noseCrest: crest, nose: [], outerLips: ring(CGPoint(x: 340, y: 300), rx: 40, ry: 10)
        ))
        #expect(points[0] == pupil)
    }

    @Test func fallsBackToNoseCentroid() throws {
        let points = try #require(FaceAlignment.fivePoints(
            leftEye: ring(eyeA, rx: 12, ry: 4), rightEye: ring(eyeB, rx: 12, ry: 4),
            noseCrest: [], nose: ring(CGPoint(x: 340, y: 250), rx: 10, ry: 6),
            outerLips: ring(CGPoint(x: 340, y: 300), rx: 40, ry: 10)
        ))
        #expect(abs(points[2].x - 340) < 1e-6 && abs(points[2].y - 250) < 1e-6)
    }

    @Test func missingRegionsGiveNil() {
        #expect(FaceAlignment.fivePoints(leftEye: [], rightEye: [eyeB], noseCrest: crest, nose: [], outerLips: [eyeA, eyeB]) == nil)
        #expect(FaceAlignment.fivePoints(leftEye: [eyeA], rightEye: [eyeB], noseCrest: [], nose: [], outerLips: [eyeA, eyeB]) == nil)
        #expect(FaceAlignment.fivePoints(leftEye: [eyeA], rightEye: [eyeB], noseCrest: crest, nose: [], outerLips: [eyeA]) == nil)
    }
}

/// Geometry of the real Core Image warp: coloured markers placed at the face's 5 points must land
/// on OpenCV's reference points in the 112x112 output, and outside the image must be black.
struct AlignedFaceTests {
    private struct Marker {
        let at: CGPoint
        let bgr: (UInt8, UInt8, UInt8)
    }

    private let colours: [(UInt8, UInt8, UInt8)] = [(0, 0, 255), (0, 255, 0), (255, 0, 0), (0, 255, 255), (255, 255, 0)]

    private func frame(width: Int, height: Int, markers: [Marker], radius: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                (base[offset], base[offset + 1], base[offset + 2], base[offset + 3]) = (40, 40, 40, 255)
            }
        }
        for marker in markers {
            let cx = Int(marker.at.x.rounded()), cy = Int(marker.at.y.rounded())
            for y in (cy - radius)...(cy + radius) where y >= 0 && y < height {
                for x in (cx - radius)...(cx + radius) where x >= 0 && x < width {
                    let offset = y * rowBytes + x * 4
                    (base[offset], base[offset + 1], base[offset + 2]) = marker.bgr
                }
            }
        }
        return pixelBuffer
    }

    private func pixel(_ buffer: CVPixelBuffer, _ point: CGPoint) throws -> (UInt8, UInt8, UInt8) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let offset = Int(point.y) * CVPixelBufferGetBytesPerRow(buffer) + Int(point.x) * 4
        return (base[offset], base[offset + 1], base[offset + 2])
    }

    private func near(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8), tolerance: Int = 60) -> Bool {
        abs(Int(a.0) - Int(b.0)) <= tolerance && abs(Int(a.1) - Int(b.1)) <= tolerance && abs(Int(a.2) - Int(b.2)) <= tolerance
    }

    @Test(arguments: [(0.0, 2.5), (15.0, 2.5), (-25.0, 3.0)])
    func markersLandOnReferencePoints(degrees: Double, scale: Double) throws {
        let r = degrees * .pi / 180
        let a = scale * cos(r), b = scale * sin(r)
        let placement = CGAffineTransform(a: a, b: b, c: -b, d: a, tx: 220, ty: 70)
        let facePoints = FaceAlignment.referencePoints.map { $0.applying(placement) }
        let markers = zip(facePoints, colours).map { Marker(at: $0, bgr: $1) }
        let source = try frame(width: 640, height: 480, markers: markers, radius: 5)

        let aligned = try FaceAlignment.alignedFace(from: source, points: facePoints)
        #expect(CVPixelBufferGetWidth(aligned) == 112 && CVPixelBufferGetHeight(aligned) == 112)
        for (target, colour) in zip(FaceAlignment.referencePoints, colours) {
            let sample = try pixel(aligned, CGPoint(x: target.x.rounded(), y: target.y.rounded()))
            #expect(near(sample, colour), "expected \(colour) at \(target), got \(sample)")
        }
        // A spot between the markers shows the grey background, not a marker.
        #expect(near(try pixel(aligned, CGPoint(x: 56, y: 30)), (40, 40, 40), tolerance: 10))
    }

    @Test func areaOutsideTheImageIsBlack() throws {
        // Face near the top-left corner, so the crop reaches past the image edge.
        let placement = CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: -30, ty: -40)
        let facePoints = FaceAlignment.referencePoints.map { $0.applying(placement) }
        let source = try frame(width: 640, height: 480, markers: [], radius: 0)
        let aligned = try FaceAlignment.alignedFace(from: source, points: facePoints)
        #expect(near(try pixel(aligned, CGPoint(x: 2, y: 2)), (0, 0, 0), tolerance: 5))
        #expect(near(try pixel(aligned, CGPoint(x: 100, y: 100)), (40, 40, 40), tolerance: 10))
    }

    @Test func wrongPointCountIsRejected() throws {
        let source = try frame(width: 64, height: 64, markers: [], radius: 0)
        #expect(throws: FaceIDError.embeddingFailed) {
            _ = try FaceAlignment.alignedFace(from: source, points: Array(FaceAlignment.referencePoints.prefix(4)))
        }
    }
}
