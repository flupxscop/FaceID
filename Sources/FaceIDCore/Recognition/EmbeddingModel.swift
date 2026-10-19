import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision

/// Core ML face-embedding model (OpenCV Zoo SFace, see Models/README.md).
///
/// The model takes one aligned 112x112 RGB face (0-255) and produces one embedding MultiArray.
/// Faces are aligned here with `FaceAlignment` (5 landmarks), exactly as the model was trained;
/// frames without alignment points are rejected earlier by `QualityGate`.
public actor CoreMLEmbeddingModel: EmbeddingProviding {
    public nonisolated let modelIdentifier: String
    private let model: VNCoreMLModel
    private let imageContext = FaceAlignment.makeContext()

    public init(compiledModelURL: URL, modelIdentifier: String) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        do {
            let mlModel = try MLModel(contentsOf: compiledModelURL, configuration: configuration)
            self.model = try VNCoreMLModel(for: mlModel)
        } catch {
            throw FaceIDError.modelLoadFailed
        }
        self.modelIdentifier = modelIdentifier
    }

    /// Loads a `.mlmodelc`, compiling a `.mlpackage`/`.mlmodel` first if needed.
    public static func load(modelURL: URL, modelIdentifier: String) async throws -> CoreMLEmbeddingModel {
        var compiledURL = modelURL
        if modelURL.pathExtension != "mlmodelc" {
            do {
                compiledURL = try await MLModel.compileModel(at: modelURL)
            } catch {
                throw FaceIDError.modelLoadFailed
            }
        }
        return try CoreMLEmbeddingModel(compiledModelURL: compiledURL, modelIdentifier: modelIdentifier)
    }

    public func embedding(for frame: CameraFrame, face: FaceObservation) async throws -> FaceEmbedding {
        guard let points = face.landmarks?.alignmentPoints else { throw FaceIDError.embeddingFailed }
        let aligned = try FaceAlignment.alignedFace(from: frame.pixelBuffer, points: points, context: imageContext)

        let request = VNCoreMLRequest(model: model)
        // Already exactly 112x112: no further cropping or scaling.
        request.imageCropAndScaleOption = .scaleFill

        let handler = VNImageRequestHandler(cvPixelBuffer: aligned, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw FaceIDError.embeddingFailed
        }

        guard let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
              let array = observation.featureValue.multiArrayValue,
              array.count > 0
        else { throw FaceIDError.embeddingFailed }

        let vector = (0..<array.count).map { array[$0].floatValue }
        guard vector.allSatisfy(\.isFinite) else { throw FaceIDError.embeddingFailed }
        return FaceEmbedding(vector)
    }
}
