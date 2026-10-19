import CoreGraphics
import Testing
@testable import FaceIDCore

struct FrameDiagnosticsTests {
    private func analysis(at time: Double, faces: Int, yaw: Double = 3.4, pitch: Double = -12.6) -> FrameAnalysis {
        let face = FaceObservation(boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
                                   rollDegrees: 1, yawDegrees: yaw, pitchDegrees: pitch)
        return FrameAnalysis(timestamp: time, faces: Array(repeating: face, count: faces), metrics: nil)
    }

    @Test func summarisesOncePerInterval() throws {
        var diagnostics = FrameDiagnostics(label: "enrollment")
        let early = [
            diagnostics.record(analysis(at: 0.0, faces: 1), issue: .badPose),
            diagnostics.record(analysis(at: 0.3, faces: 0), issue: .noFace),
            diagnostics.record(analysis(at: 0.6, faces: 2), issue: .multipleFaces),
            diagnostics.record(analysis(at: 0.8, faces: 1), issue: nil, accepted: true),
        ]
        #expect(early.allSatisfy { $0 == nil })
        let summary = diagnostics.record(analysis(at: 1.1, faces: 1), issue: .blurry)
        let line = try #require(summary)
        #expect(line.contains("frames 5"))
        #expect(line.contains("no face 1"))
        #expect(line.contains("several faces 1"))
        #expect(line.contains("usable 1"))
        #expect(line.contains("accepted 1"))
        #expect(line.contains("badPose=1"))
        #expect(line.contains("blurry=1"))
        #expect(line.contains("yaw 3 pitch -13 roll 1"))
    }

    @Test func startsAFreshWindowAfterReporting() throws {
        var diagnostics = FrameDiagnostics(label: "scan")
        _ = diagnostics.record(analysis(at: 0, faces: 1), issue: nil)
        let first = diagnostics.record(analysis(at: 1.0, faces: 1), issue: nil)
        let quiet = diagnostics.record(analysis(at: 1.5, faces: 1), issue: nil)
        let second = diagnostics.record(analysis(at: 2.6, faces: 1), issue: nil)
        #expect(first != nil)
        #expect(quiet == nil)
        let next = try #require(second)
        #expect(next.contains("frames 2"))
    }

    @Test func countsWhyUsableFramesWereNotStored() throws {
        var diagnostics = FrameDiagnostics(label: "enrollment")
        _ = diagnostics.record(analysis(at: 0, faces: 1), issue: nil, accepted: false, notStoredBecause: "ambiguousPose")
        _ = diagnostics.record(analysis(at: 0.5, faces: 1), issue: nil, accepted: false, notStoredBecause: "ambiguousPose")
        let summary = diagnostics.record(analysis(at: 1.0, faces: 1), issue: nil, accepted: false, notStoredBecause: "notConsistent")
        let line = try #require(summary)
        #expect(line.contains("not stored [ambiguousPose=2 notConsistent=1]"))
    }

    @Test func containsNoBiometricValues() throws {
        var diagnostics = FrameDiagnostics(label: "scan")
        _ = diagnostics.record(analysis(at: 0, faces: 1), issue: nil)
        let summary = diagnostics.record(analysis(at: 2, faces: 1), issue: nil)
        let line = try #require(summary).lowercased()
        for word in ["embedding", "similarity", "score", "template"] {
            #expect(!line.contains(word))
        }
    }
}
