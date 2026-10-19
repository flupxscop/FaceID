import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import FaceIDCore

/// Runs the real converted model (Models/FaceEmbedding.mlpackage) through `CoreMLEmbeddingModel`.
/// Skipped when the model has not been converted yet (see Models/README.md). No camera involved.
struct EmbeddingModelTests {
    static let modelURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Models/FaceEmbedding.mlpackage")
    static let modelPresent = FileManager.default.fileExists(atPath: modelURL.path)

    /// 640x480 BGRA frame filled by `pixel(x, y) -> (b, g, r)`.
    private func frame(_ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CameraFrame {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<480 {
            for x in 0..<640 {
                let (b, g, r) = pixel(x, y)
                let offset = y * rowBytes + x * 4
                base[offset] = b
                base[offset + 1] = g
                base[offset + 2] = r
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return CameraFrame(pixelBuffer: pixelBuffer, timestamp: 0, sequenceNumber: 0)
    }

    private let face = FaceObservation(
        boundingBox: CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.4),
        landmarks: FaceLandmarks(leftEye: [], rightEye: [], alignmentPoints: sampleAlignmentPoints)
    )

    @Test(.enabled(if: modelPresent, "Models/FaceEmbedding.mlpackage not converted yet"))
    func refusesFacesWithoutAlignmentPoints() async throws {
        let model = try await CoreMLEmbeddingModel.load(modelURL: Self.modelURL, modelIdentifier: "sface-test")
        let unaligned = FaceObservation(boundingBox: CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.4))
        await #expect(throws: FaceIDError.embeddingFailed) {
            _ = try await model.embedding(for: try frame { _, _ in (0, 0, 0) }, face: unaligned)
        }
    }

    @Test(.enabled(if: modelPresent, "Models/FaceEmbedding.mlpackage not converted yet"))
    func producesA128DimensionalFiniteEmbedding() async throws {
        let model = try await CoreMLEmbeddingModel.load(modelURL: Self.modelURL, modelIdentifier: "sface-test")
        let embedding = try await model.embedding(for: try frame { x, y in (UInt8(x % 256), UInt8(y % 256), 128) }, face: face)
        #expect(embedding.dimension == 128)
        let allFinite = embedding.vector.allSatisfy { $0.isFinite }
        let anyNonZero = embedding.vector.contains { $0 != 0 }
        #expect(allFinite)
        #expect(anyNonZero)
    }

    @Test(.enabled(if: modelPresent, "Models/FaceEmbedding.mlpackage not converted yet"))
    func isDeterministicAndDiscriminates() async throws {
        let model = try await CoreMLEmbeddingModel.load(modelURL: Self.modelURL, modelIdentifier: "sface-test")
        let stripes = try frame { x, _ in x % 16 < 8 ? (20, 40, 200) : (200, 180, 30) }
        let gradient = try frame { x, y in (UInt8(y % 256), UInt8(x % 256), UInt8((x + y) % 256)) }

        let first = try await model.embedding(for: stripes, face: face)
        let again = try await model.embedding(for: stripes, face: face)
        let other = try await model.embedding(for: gradient, face: face)

        let same = try #require(Matcher.cosineSimilarity(first.vector, again.vector))
        let different = try #require(Matcher.cosineSimilarity(first.vector, other.vector))
        #expect(same > 0.9999)
        #expect(different < same)
    }
}
