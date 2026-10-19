import FaceIDCore
import Foundation

/// The master switch the agent reads on every request (CLAUDE.md §7.9: one click to disable).
public protocol EnabledSettingStoring: Sendable {
    func setEnabled(_ enabled: Bool)
}

/// Same preferences domain and key the agent reads (`UserDefaultsAgentSettings`).
public struct UserDefaultsEnabledSetting: EnabledSettingStoring {
    public static let suiteName = FaceIDConfig.logSubsystem
    public static let enabledKey = "enabled"

    public init() {}

    public func setEnabled(_ enabled: Bool) {
        UserDefaults(suiteName: Self.suiteName)?.set(enabled, forKey: Self.enabledKey)
    }
}
