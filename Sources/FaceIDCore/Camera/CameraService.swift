import AVFoundation
import CoreMedia
import Foundation

/// AVFoundation camera. Frames are delivered in memory only and never written to disk.
///
/// All mutable state is confined to `queue`, which is also the sample-buffer delegate queue,
/// hence `@unchecked Sendable`.
public final class CameraService: NSObject, CameraProviding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.example.faceid.camera")
    private let preferredDeviceID: String?
    private var session: AVCaptureSession?
    private var continuation: AsyncThrowingStream<CameraFrame, Error>.Continuation?
    private var sequenceNumber = 0

    public init(preferredDeviceID: String? = nil) {
        self.preferredDeviceID = preferredDeviceID
        super.init()
    }

    public static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Prompts for camera access. Call from the menu bar app during enrollment — never at the lock screen.
    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    public static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    public func frames() async throws -> AsyncThrowingStream<CameraFrame, Error> {
        guard Self.isAuthorized else { throw FaceIDError.cameraPermissionDenied }

        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: CameraFrame.self,
            throwing: Error.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.teardown() }
        }

        try await withCheckedThrowingContinuation { (started: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.startSession(continuation: continuation)
                    started.resume()
                } catch {
                    continuation.finish(throwing: error)
                    started.resume(throwing: error)
                }
            }
        }
        return stream
    }

    public func stop() async {
        await withCheckedContinuation { (stopped: CheckedContinuation<Void, Never>) in
            queue.async {
                self.teardown()
                stopped.resume()
            }
        }
    }

    // MARK: - Queue-confined

    private func startSession(continuation: AsyncThrowingStream<CameraFrame, Error>.Continuation) throws {
        guard session == nil else { throw FaceIDError.busy }

        let devices = Self.availableDevices()
        guard let device = devices.first(where: { $0.uniqueID == preferredDeviceID })
            ?? devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? devices.first
        else { throw FaceIDError.cameraUnavailable }

        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        }

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            throw FaceIDError.cameraUnavailable
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw FaceIDError.cameraUnavailable
        }
        session.addOutput(output)
        session.commitConfiguration()

        self.session = session
        self.continuation = continuation
        sequenceNumber = 0
        session.startRunning()
        Log.camera.info("camera started")
    }

    private func teardown() {
        guard let session else { return }
        session.stopRunning()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        self.session = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.finish()
        Log.camera.info("camera stopped")
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let continuation, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        sequenceNumber += 1
        continuation.yield(CameraFrame(
            pixelBuffer: pixelBuffer,
            timestamp: time.isFinite ? time : Date().timeIntervalSinceReferenceDate,
            sequenceNumber: sequenceNumber
        ))
    }
}
