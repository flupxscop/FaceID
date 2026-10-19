import Foundation

public struct Matcher: Sendable {
    public let threshold: Float

    public init(threshold: Float = FaceIDConfig.matchThreshold) {
        self.threshold = threshold
    }

    /// Cosine similarity in -1...1, or nil when the vectors cannot be compared
    /// (different dimensions, empty, zero norm or non-finite values).
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return nil }
        let similarity = dot / (normA.squareRoot() * normB.squareRoot())
        guard similarity.isFinite else { return nil }
        return min(max(similarity, -1), 1)
    }

    /// Highest similarity between the probe and any enrolled embedding.
    public func bestSimilarity(_ probe: FaceEmbedding, templates: [FaceEmbedding]) -> Float? {
        templates.compactMap { Self.cosineSimilarity(probe.vector, $0.vector) }.max()
    }

    public func matches(_ probe: FaceEmbedding, templates: [FaceEmbedding]) -> Bool {
        guard let similarity = bestSimilarity(probe, templates: templates) else { return false }
        #if DEBUG
        Log.recognition.debug("similarity \(similarity, privacy: .private)")
        #endif
        return similarity >= threshold
    }
}

/// Requires several consecutive matching frames before accepting.
public struct ConsecutiveMatchTracker: Sendable {
    public let required: Int
    public private(set) var count = 0

    public init(required: Int = FaceIDConfig.requiredConsecutiveMatches) {
        self.required = max(1, required)
    }

    public var isSatisfied: Bool { count >= required }

    /// Records one frame's result and returns whether the streak is now long enough.
    @discardableResult
    public mutating func record(_ matched: Bool) -> Bool {
        count = matched ? count + 1 : 0
        return isSatisfied
    }

    public mutating func reset() {
        count = 0
    }
}

/// Counts failed face attempts. Once locked out, only a successful password
/// authentication may reset it.
public struct AttemptLimiter: Sendable {
    public let maxAttempts: Int
    public private(set) var failures = 0

    public init(maxAttempts: Int = FaceIDConfig.maxAttemptsBeforeLockout) {
        self.maxAttempts = max(1, maxAttempts)
    }

    public var isLockedOut: Bool { failures >= maxAttempts }

    public mutating func recordFailure() {
        failures += 1
    }

    public mutating func recordSuccess() {
        guard !isLockedOut else { return }
        failures = 0
    }

    public mutating func resetAfterPasswordAuthentication() {
        failures = 0
    }
}
