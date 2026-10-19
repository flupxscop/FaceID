import CoreGraphics
import Foundation

/// Clears the face lockout after the user unlocks the screen (which, while locked out, can only
/// happen with the password). No caller can reset the lockout over XPC.
///
/// The distributed notification can be posted by any process, so it is only a trigger:
/// the reset happens only if the window server also reports the session as unlocked.
/// The notification can arrive before the window server updates its state (seen in a VM),
/// so the state is re-checked for a short while before giving up.
public final class ScreenUnlockMonitor: @unchecked Sendable {
    public enum SessionState: Sendable, Equatable {
        case unlocked
        case locked
        /// The window server gave no answer; treated as locked (fail closed).
        case unknown
    }

    public static let unlockNotification = Notification.Name("com.apple.screenIsUnlocked")

    private let coordinator: AuthenticationCoordinator
    private let sessionState: @Sendable () -> SessionState
    private let recheckInterval: Duration
    private let recheckAttempts: Int
    private var observer: NSObjectProtocol?   // set once in start(), read only in deinit

    public init(
        coordinator: AuthenticationCoordinator,
        sessionState: @escaping @Sendable () -> SessionState = ScreenUnlockMonitor.currentSessionState,
        recheckInterval: Duration = .milliseconds(250),
        recheckAttempts: Int = 12
    ) {
        self.coordinator = coordinator
        self.sessionState = sessionState
        self.recheckInterval = recheckInterval
        self.recheckAttempts = max(1, recheckAttempts)
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    public func start() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.unlockNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleUnlockSignal() }
        }
    }

    /// Returns whether the lockout was reset.
    @discardableResult
    func handleUnlockSignal() async -> Bool {
        var state = sessionState()
        var attempt = 1
        while state != .unlocked && attempt < recheckAttempts {
            try? await Task.sleep(for: recheckInterval)
            state = sessionState()
            attempt += 1
        }
        switch state {
        case .unlocked:
            await coordinator.resetLockout()
            return true
        case .locked:
            AgentLog.lifecycle.notice("ignored unlock notification: the session is still locked")
            return false
        case .unknown:
            AgentLog.lifecycle.notice("ignored unlock notification: session state unavailable")
            return false
        }
    }

    /// Asks the window server.
    public static let currentSessionState: @Sendable () -> SessionState = {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return .unknown }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true ? .locked : .unlocked
    }
}
