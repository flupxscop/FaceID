import CoreGraphics
import Testing
@testable import FaceIDCore

struct FaceAuthenticatorTests {
    private func makeAuthenticator(
        camera: MockCamera,
        script: [FrameScript] = livePersonScript(),
        embedding: FaceEmbedding = ownerEmbedding,
        template: EnrolledTemplate? = EnrolledTemplate(modelIdentifier: testModelID, embeddings: [ownerEmbedding]),
        challenge: LivenessChallenge = .turnLeft
    ) -> FaceAuthenticator {
        FaceAuthenticator(
            camera: camera,
            analyzer: ScriptedAnalyzer(script: script),
            embedder: FixedEmbedder(modelIdentifier: testModelID, output: embedding),
            store: InMemoryTemplateStore(template),
            timeout: .milliseconds(300),
            challengeProvider: { challenge }
        )
    }

    @Test func livePersonMatches() async {
        let script = livePersonScript()
        let camera = MockCamera(frameCount: script.count)
        let outcome = await makeAuthenticator(camera: camera, script: script).authenticate()
        #expect(outcome == .match)
        #expect(camera.stopCount == 1)
    }

    @Test func strangerDoesNotMatch() async {
        let script = livePersonScript()
        let camera = MockCamera(frameCount: script.count)
        let outcome = await makeAuthenticator(camera: camera, script: script, embedding: strangerEmbedding).authenticate()
        #expect(outcome == .noMatch)
        #expect(camera.stopCount == 1)
    }

    @Test func stillPhotoOfOwnerFailsLiveness() async {
        let script = Array(repeating: FrameScript(), count: 60)
        let camera = MockCamera(frameCount: script.count)
        let outcome = await makeAuthenticator(camera: camera, script: script).authenticate()
        #expect(outcome == .livenessFailed)
    }

    @Test func wrongChallengeDirectionFailsLiveness() async {
        let script = livePersonScript()
        let camera = MockCamera(frameCount: script.count)
        let outcome = await makeAuthenticator(camera: camera, script: script, challenge: .turnRight).authenticate()
        #expect(outcome == .livenessFailed)
    }

    @Test func noFramesTimesOut() async {
        let camera = MockCamera(frameCount: 0)
        let outcome = await makeAuthenticator(camera: camera).authenticate()
        #expect(outcome == .timeout)
        #expect(camera.stopCount == 1)
    }

    @Test func noFaceTimesOut() async {
        let script = Array(repeating: FrameScript(faces: 0), count: 20)
        let outcome = await makeAuthenticator(camera: MockCamera(frameCount: 20), script: script).authenticate()
        #expect(outcome == .timeout)
    }

    @Test func secondFaceInFrameBlocksMatch() async {
        var script = livePersonScript()
        // A second face appears every other frame, so the match streak never completes.
        for i in script.indices where i % 2 == 0 { script[i].faces = 2 }
        let outcome = await makeAuthenticator(camera: MockCamera(frameCount: script.count), script: script).authenticate()
        #expect(outcome != .match)
    }

    @Test func notEnrolled() async {
        let outcome = await makeAuthenticator(camera: MockCamera(frameCount: 0), template: nil).authenticate()
        #expect(outcome == .error(.notEnrolled))
    }

    @Test func keychainApprovalNeededFailsFastWithoutCamera() async {
        let camera = MockCamera(frameCount: 0)
        let authenticator = FaceAuthenticator(
            camera: camera,
            analyzer: ScriptedAnalyzer(script: [FrameScript()]),
            embedder: FixedEmbedder(modelIdentifier: testModelID, output: ownerEmbedding),
            store: ApprovalNeededStore(),
            timeout: .seconds(5)
        )
        let start = ContinuousClock.now
        #expect(await authenticator.authenticate() == .error(.keychainApprovalNeeded))
        #expect(ContinuousClock.now - start < .seconds(1), "must not wait at the lock screen")
    }

    @Test func templateFromDifferentModelIsRejected() async {
        let template = EnrolledTemplate(modelIdentifier: "other-model", embeddings: [ownerEmbedding])
        let outcome = await makeAuthenticator(camera: MockCamera(frameCount: 0), template: template).authenticate()
        #expect(outcome == .error(.invalidTemplate))
    }

    @Test func cameraPermissionErrorIsReported() async {
        let camera = MockCamera(frameCount: 0, startError: .cameraPermissionDenied)
        let outcome = await makeAuthenticator(camera: camera).authenticate()
        #expect(outcome == .error(.cameraPermissionDenied))
        #expect(camera.stopCount == 1)
    }

    @Test func locksOutAfterRepeatedFailuresUntilPassword() async {
        let script = livePersonScript()
        let camera = MockCamera(frameCount: script.count)
        let authenticator = makeAuthenticator(camera: camera, script: script, embedding: strangerEmbedding)

        for _ in 0..<FaceIDConfig.maxAttemptsBeforeLockout {
            #expect(await authenticator.authenticate() == .noMatch)
        }
        #expect(await authenticator.isLockedOut)
        #expect(await authenticator.authenticate() == .error(.lockedOut))

        await authenticator.resetAfterPasswordAuthentication()
        #expect(await !authenticator.isLockedOut)
    }

    @Test func cameraStreamEndingEarlyIsNotAMatch() async {
        let camera = MockCamera(frameCount: 4, keepOpen: false)
        let outcome = await makeAuthenticator(camera: camera).authenticate()
        #expect(outcome != .match)
    }
}

/// Liveness must come from the same, continuously matched face (found while spoof-testing on a
/// real Mac: liveness passed while a phone photo was in view).
struct LivenessBindingTests {
    private func authenticator(script: [FrameScript], embeddings: [FaceEmbedding]) -> (FaceAuthenticator, MockCamera) {
        let camera = MockCamera(frameCount: script.count)
        let authenticator = FaceAuthenticator(
            camera: camera,
            analyzer: ScriptedAnalyzer(script: script),
            embedder: SequenceEmbedder(modelIdentifier: testModelID, outputs: embeddings),
            store: InMemoryTemplateStore(EnrolledTemplate(modelIdentifier: testModelID, embeddings: [ownerEmbedding])),
            timeout: .milliseconds(300),
            challengeProvider: { .turnLeft }
        )
        return (authenticator, camera)
    }

    @Test func attackersLivenessDoesNotCountForOwnersPhoto() async {
        // The attacker blinks and turns with their own face, then holds up a still photo of the owner.
        let live = livePersonScript()
        let photo = Array(repeating: FrameScript(), count: 20)
        let embeddings = Array(repeating: strangerEmbedding, count: live.count) + Array(repeating: ownerEmbedding, count: photo.count)
        let (auth, _) = authenticator(script: live + photo, embeddings: embeddings)
        let outcome = await auth.authenticate()
        #expect(outcome != .match)
        #expect(outcome == .livenessFailed)
    }

    @Test func livenessFromAFaceElsewhereInTheFrameDoesNotCount() async {
        // Owner photo at one place; a live face elsewhere blinks and turns in frames too poor to compare.
        var script = Array(repeating: FrameScript(), count: 5)
        script += livePersonScript().map { var step = $0; step.x = 0.0; step.quality = 0.3; return step }
        script += Array(repeating: FrameScript(), count: 15)
        let (auth, _) = authenticator(script: script, embeddings: [ownerEmbedding])
        let outcome = await auth.authenticate()
        #expect(outcome != .match)
    }

    @Test func ownerStillMatchesWithContinuousFace() async {
        let script = livePersonScript()
        let (auth, camera) = authenticator(script: script, embeddings: [ownerEmbedding])
        #expect(await auth.authenticate() == .match)
        #expect(camera.stopCount == 1)
    }

    @Test func continuityLimits() {
        let box = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        #expect(FaceAuthenticator.isContinuous(box, box.offsetBy(dx: 0.05, dy: 0.02)))
        #expect(!FaceAuthenticator.isContinuous(box, box.offsetBy(dx: 0.3, dy: 0)))
        #expect(!FaceAuthenticator.isContinuous(box, CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)))
        #expect(!FaceAuthenticator.isContinuous(box, .zero))
    }
}

struct AuthResultCodeTests {
    @Test func unknownValuesFailClosed() {
        #expect(AuthResultCode(xpcValue: nil) == .error)
        #expect(AuthResultCode(xpcValue: 99) == .error)
        #expect(AuthResultCode(xpcValue: -1) == .error)
    }

    @Test func onlyMatchAllowsUnlock() {
        #expect(AuthResultCode.match.allowsUnlock)
        for code in [AuthResultCode.noMatch, .livenessFailed, .timeout, .error] {
            #expect(!code.allowsUnlock)
        }
    }

    @Test func outcomeMapping() {
        #expect(AuthOutcome.match.resultCode == .match)
        #expect(AuthOutcome.error(.busy).resultCode == .error)
    }
}

struct ApprovalNeededStore: TemplateStoring {
    func load() throws -> EnrolledTemplate? { throw FaceIDError.keychainApprovalNeeded }
    func save(_ template: EnrolledTemplate) throws {}
    func delete() throws {}
}
