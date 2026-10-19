import FaceIDCore
import Foundation

public protocol AgentSettingsProviding: Sendable {
    /// Master switch toggled from the menu bar. Read on every request so disabling takes effect immediately.
    var isEnabled: Bool { get }
}

/// Shared preferences domain written by the menu bar app. Missing value = disabled.
public struct UserDefaultsAgentSettings: AgentSettingsProviding {
    public static let enabledKey = "enabled"
    private let suiteName: String

    public init(suiteName: String = FaceIDConfig.logSubsystem) {
        self.suiteName = suiteName
    }

    public var isEnabled: Bool {
        UserDefaults(suiteName: suiteName)?.bool(forKey: Self.enabledKey) ?? false
    }
}
