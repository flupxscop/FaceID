import Testing
@testable import FaceIDCore

struct MatcherTests {
    @Test func identicalVectorsHaveSimilarityOne() throws {
        let similarity = try #require(Matcher.cosineSimilarity([1, 2, 3], [1, 2, 3]))
        #expect(abs(similarity - 1) < 1e-6)
    }

    @Test func similarityIsScaleInvariant() throws {
        let similarity = try #require(Matcher.cosineSimilarity([1, 2, 3], [2, 4, 6]))
        #expect(abs(similarity - 1) < 1e-6)
    }

    @Test func orthogonalVectorsHaveSimilarityZero() {
        #expect(Matcher.cosineSimilarity([1, 0], [0, 1]) == 0)
    }

    @Test(arguments: [
        ([Float](), [Float]()),
        ([1, 2], [1, 2, 3]),
        ([0, 0], [1, 1]),
        ([.nan, 1], [1, 1]),
        ([.infinity, 1], [1, 1]),
    ])
    func incomparableVectorsReturnNil(a: [Float], b: [Float]) {
        #expect(Matcher.cosineSimilarity(a, b) == nil)
    }

    @Test func similarityExactlyAtThresholdMatches() {
        // cos(angle) = 0.6 for (0.6, 0.8) vs (1, 0).
        let matcher = Matcher(threshold: 0.6)
        #expect(matcher.matches(FaceEmbedding([0.6, 0.8]), templates: [FaceEmbedding([1, 0])]))
    }

    @Test func similarityJustBelowThresholdDoesNotMatch() {
        let matcher = Matcher(threshold: 0.6001)
        #expect(!matcher.matches(FaceEmbedding([0.6, 0.8]), templates: [FaceEmbedding([1, 0])]))
    }

    @Test func usesBestOfSeveralTemplates() {
        let matcher = Matcher()
        let templates = [FaceEmbedding([0, 1]), FaceEmbedding([1, 0.1])]
        #expect(matcher.matches(FaceEmbedding([1, 0]), templates: templates))
    }

    @Test func noTemplatesNeverMatches() {
        #expect(!Matcher().matches(ownerEmbedding, templates: []))
    }

    @Test func dimensionMismatchNeverMatches() {
        #expect(!Matcher().matches(FaceEmbedding([1, 0]), templates: [ownerEmbedding]))
    }

    @Test func defaultThresholdComesFromConfig() {
        #expect(Matcher().threshold == FaceIDConfig.matchThreshold)
    }
}

struct ConsecutiveMatchTrackerTests {
    @Test func requiresConsecutiveMatches() {
        var tracker = ConsecutiveMatchTracker(required: 3)
        let first = tracker.record(true)
        let second = tracker.record(true)
        let third = tracker.record(true)
        #expect(!first && !second && third)
    }

    @Test func nonMatchResetsStreak() {
        var tracker = ConsecutiveMatchTracker(required: 3)
        tracker.record(true)
        tracker.record(true)
        tracker.record(false)
        let satisfied = tracker.record(true)
        #expect(!satisfied)
        #expect(tracker.count == 1)
    }
}

struct AttemptLimiterTests {
    @Test func locksOutAfterMaxFailures() {
        var limiter = AttemptLimiter(maxAttempts: 3)
        limiter.recordFailure()
        limiter.recordFailure()
        #expect(!limiter.isLockedOut)
        limiter.recordFailure()
        #expect(limiter.isLockedOut)
    }

    @Test func successDoesNotClearLockout() {
        var limiter = AttemptLimiter(maxAttempts: 1)
        limiter.recordFailure()
        limiter.recordSuccess()
        #expect(limiter.isLockedOut)
        limiter.resetAfterPasswordAuthentication()
        #expect(!limiter.isLockedOut)
    }

    @Test func successBeforeLockoutResetsFailures() {
        var limiter = AttemptLimiter(maxAttempts: 3)
        limiter.recordFailure()
        limiter.recordFailure()
        limiter.recordSuccess()
        #expect(limiter.failures == 0)
    }
}
