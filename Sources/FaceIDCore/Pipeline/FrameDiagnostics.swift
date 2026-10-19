import Foundation

/// Once-a-second summary of what the camera pipeline sees, so "it does not detect my face" can be
/// diagnosed from the log: frame rate, face count, why frames were rejected, and the head pose.
///
/// Logs no images, embeddings or similarity scores (CLAUDE.md §7.3) — only counts and rounded
/// head-pose angles, which do not identify anyone.
struct FrameDiagnostics {
    let label: String
    var interval: TimeInterval = 1

    private var windowStart: TimeInterval?
    private var frames = 0
    private var noFace = 0
    private var multipleFaces = 0
    private var rejected: [QualityIssue: Int] = [:]
    private var notStored: [String: Int] = [:]
    private var usable = 0
    private var accepted = 0
    private var yaw: Double?
    private var pitch: Double?
    private var roll: Double?

    init(label: String) {
        self.label = label
    }

    /// `accepted` is nil when the caller has no notion of accepting (e.g. a scan).
    mutating func record(
        _ analysis: FrameAnalysis,
        issue: QualityIssue?,
        accepted wasAccepted: Bool? = nil,
        notStoredBecause reason: String? = nil
    ) -> String? {
        if windowStart == nil { windowStart = analysis.timestamp }
        frames += 1
        switch analysis.faces.count {
        case 0: noFace += 1
        case 1:
            let face = analysis.faces[0]
            yaw = face.yawDegrees
            pitch = face.pitchDegrees
            roll = face.rollDegrees
        default: multipleFaces += 1
        }
        if let issue, issue != .noFace, issue != .multipleFaces {
            rejected[issue, default: 0] += 1
        } else if issue == nil {
            usable += 1
        }
        if wasAccepted == true { accepted += 1 }
        if let reason { notStored[reason, default: 0] += 1 }

        guard let start = windowStart, analysis.timestamp - start >= interval else { return nil }
        let summary = summaryLine()
        self = FrameDiagnostics(label: label)
        return summary
    }

    func summaryLine() -> String {
        let reasons = rejected
            .sorted { $0.value > $1.value }
            .map { "\($0.key.rawValue)=\($0.value)" }
            .joined(separator: " ")
        func angle(_ value: Double?) -> String { value.map { String(Int($0.rounded())) } ?? "?" }
        let skipped = notStored.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "\(label): frames \(frames), no face \(noFace), several faces \(multipleFaces), "
            + "usable \(usable), accepted \(accepted), rejected [\(reasons)], "
            + (notStored.isEmpty ? "" : "not stored [\(skipped)], ")
            + "pose yaw \(angle(yaw)) pitch \(angle(pitch)) roll \(angle(roll))"
    }
}
