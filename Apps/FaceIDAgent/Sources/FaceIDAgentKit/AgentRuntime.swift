import FaceIDCore
import Foundation

/// Production wiring for the LaunchAgent.
public final class AgentRuntime {
    public let configuration: AgentConfiguration
    public let coordinator: AuthenticationCoordinator
    private let listener: NSXPCListener
    private let delegate: AgentListenerDelegate
    private let unlockMonitor: ScreenUnlockMonitor
    private let brokerConnector: BrokerConnector?

    public init(configuration: AgentConfiguration) {
        self.configuration = configuration
        let store: any TemplateStoring
        do {
            store = try EncryptedTemplateStore.makeDefault()
        } catch {
            AgentLog.lifecycle.error("secure template storage unavailable; face unlock disabled")
            store = UnavailableTemplateStore(error: (error as? FaceIDError) ?? .internalFailure)
        }
        var unavailableReason: FaceIDError?
        if !NetworkLockdown.isNetworkBlocked() {
            if configuration.requireNetworkIsolation {
                AgentLog.lifecycle.error("network is not blocked by the sandbox; face unlock disabled")
                unavailableReason = .networkNotIsolated
            } else {
                AgentLog.lifecycle.notice("network is not blocked (debug build); run via sandbox-exec to test isolation")
            }
        }
        let modelURL = configuration.modelURL
        coordinator = AuthenticationCoordinator(
            settings: UserDefaultsAgentSettings(),
            store: store,
            requestCameraAccess: { await CameraService.requestAccess() },
            unavailableReason: unavailableReason,
            makeServices: {
                let identifier = try ModelIdentity.compute(for: modelURL)
                let model = try await CoreMLEmbeddingModel.load(modelURL: modelURL, modelIdentifier: identifier)
                // One camera and one detector shared by scan and enrollment; the coordinator serializes them.
                let camera = CameraService()
                let detector = FaceDetector()
                return FaceServices(
                    authenticator: FaceAuthenticator(camera: camera, analyzer: detector, embedder: model, store: store),
                    enroller: FaceEnroller(
                        camera: camera, analyzer: detector, embedder: model, store: store,
                        ownerVerifier: LocalAuthenticationOwnerVerifier()
                    )
                )
            }
        )
        delegate = AgentListenerDelegate(coordinator: coordinator, clientRequirement: configuration.clientRequirement)
        listener = NSXPCListener(machServiceName: FaceIDXPC.machServiceName)
        listener.delegate = delegate
        unlockMonitor = ScreenUnlockMonitor(coordinator: coordinator)
        brokerConnector = BrokerConnector.makeDefault(coordinator: coordinator, pins: InstallPins.load())
    }

    /// Starts listening and never returns.
    public func run() -> Never {
        ProcessHardening.apply()
        if configuration.clientCertificateSHA1 == nil {
            AgentLog.lifecycle.error("agent is not certificate-signed; the app cannot connect")
        }
        if brokerConnector == nil {
            AgentLog.lifecycle.error("no valid pins file; not registering with the broker (lock screen uses the password)")
        }
        unlockMonitor.start()
        listener.resume()
        brokerConnector?.start()
        AgentLog.lifecycle.info("listening on \(FaceIDXPC.machServiceName, privacy: .public)")
        // Preload the model so the first unlock does not pay for it. Failures are retried per request.
        Task { [coordinator] in await coordinator.preload() }
        dispatchMain()
    }
}

/// Stand-in when no secure storage is available: every operation fails, so face unlock fails closed.
struct UnavailableTemplateStore: TemplateStoring {
    let error: FaceIDError

    func load() throws -> EnrolledTemplate? { throw error }
    func save(_ template: EnrolledTemplate) throws { throw error }
    func delete() throws { throw error }
}
