import Testing
@testable import FaceIDCore

struct FaceEnrollerTests {
    private func makeEnroller(
        camera: MockCamera,
        script: [FrameScript] = enrollmentScript(),
        embedding: FaceEmbedding = ownerEmbedding,
        store: InMemoryTemplateStore,
        approves: Bool = true
    ) -> FaceEnroller {
        FaceEnroller(
            camera: camera,
            analyzer: ScriptedAnalyzer(script: script),
            embedder: FixedEmbedder(modelIdentifier: testModelID, output: embedding),
            store: store,
            ownerVerifier: StubOwnerVerifier(approves: approves),
            timeout: .milliseconds(500)
        )
    }

    @Test func savesTemplateAfterOwnerVerification() async throws {
        let script = enrollmentScript()
        let camera = MockCamera(frameCount: script.count)
        let store = InMemoryTemplateStore()
        let result = await makeEnroller(camera: camera, script: script, store: store).enroll()

        #expect(result.state == .completed)
        let template = try #require(try store.load())
        #expect(template.embeddings.count == FaceIDConfig.enrollmentSamples)
        #expect(template.modelIdentifier == testModelID)
        #expect(camera.stopCount == 1)
    }

    @Test func refusedOwnerVerificationDiscardsEverything() async throws {
        let script = enrollmentScript()
        let store = InMemoryTemplateStore()
        let result = await makeEnroller(camera: MockCamera(frameCount: script.count), script: script, store: store, approves: false).enroll()

        #expect(result.state == .failed)
        #expect(result.error == .ownerVerificationFailed)
        #expect(try store.load() == nil)
    }

    @Test func photoWithoutBlinkCannotBeEnrolled() async throws {
        let script = enrollmentScript(blink: false)
        let store = InMemoryTemplateStore()
        let camera = MockCamera(frameCount: script.count)
        let result = await makeEnroller(camera: camera, script: script, store: store).enroll()

        #expect(result.error == .enrollmentTimedOut)
        #expect(try store.load() == nil)
        #expect(camera.stopCount == 1)
    }

    @Test func existingTemplateSurvivesFailedEnrollment() async throws {
        let existing = EnrolledTemplate(modelIdentifier: testModelID, embeddings: [ownerEmbedding])
        let store = InMemoryTemplateStore(existing)
        let script = enrollmentScript()
        _ = await makeEnroller(camera: MockCamera(frameCount: script.count), script: script, store: store, approves: false).enroll()
        #expect(try store.load() == existing)
    }

    @Test func cameraErrorFailsEnrollment() async {
        let camera = MockCamera(frameCount: 0, startError: .cameraPermissionDenied)
        let result = await makeEnroller(camera: camera, store: InMemoryTemplateStore()).enroll()
        #expect(result.error == .cameraPermissionDenied)
        #expect(camera.stopCount == 1)
    }

    @Test func cancellationStopsCapture() async throws {
        let store = InMemoryTemplateStore()
        let camera = MockCamera(frameCount: 0)   // stays open, never completes
        let enroller = FaceEnroller(
            camera: camera,
            analyzer: ScriptedAnalyzer(script: [FrameScript()]),
            embedder: FixedEmbedder(modelIdentifier: testModelID, output: ownerEmbedding),
            store: store,
            ownerVerifier: StubOwnerVerifier(approves: true),
            timeout: .seconds(30)
        )
        let task = Task { await enroller.enroll() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.value
        #expect(result.state == .cancelled)
        #expect(camera.stopCount == 1)
        #expect(try store.load() == nil)
    }

    @Test func progressNeverExposesEmbeddings() {
        // Compile-time contract: progress only carries state, pose, fraction and a blink flag.
        let mirror = Mirror(reflecting: EnrollmentProgress.idle)
        #expect(Set(mirror.children.compactMap(\.label)) == ["state", "nextPose", "fraction", "blinkDetected", "error"])
    }
}
