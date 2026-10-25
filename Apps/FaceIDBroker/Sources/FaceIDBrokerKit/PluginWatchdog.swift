import FaceIDCore
import Foundation
import Security

/// Keeps the lock screen from failing open when the plugin cannot load.
///
/// macOS treats a mechanism whose plugin is missing or unloadable as a success (SecurityAgent
/// runs `builtin:no-op` instead), so while `system.login.screensaver` points at the face right,
/// a deleted or damaged plugin bundle unlocks the screen without a password (seen in a VM on
/// 2026-10-25; no rule shape avoids it). The broker runs as root and is always up, so it watches
/// the bundle and, when it is unhealthy, puts the original rule back with
/// `uninstall.sh --restore-authdb-only` — the only authorizationdb change it may make
/// (CLAUDE.md §7 rule 7). It never writes a rule itself.
public final class PluginWatchdog: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The screensaver rule does not use the plugin: nothing to protect.
        case notInstalled
        case healthy
        /// install.sh is replacing the plugin right now.
        case skippedForMaintenance
        case restored
        /// Tried and failed; tried again on the next check.
        case restoreFailed
    }

    public static let pluginsDirectory = URL(fileURLWithPath: "/Library/Security/SecurityAgentPlugins")
    public static let pluginBundleURL = pluginsDirectory.appendingPathComponent("FaceIDAuthPlugin.bundle")
    public static let pluginBundleIdentifier = "com.example.faceid.authplugin"
    public static let defaultInterval: DispatchTimeInterval = .seconds(5)

    private let health: any PluginHealthChecking
    private let rule: any ScreenRuleInspecting
    private let restorer: any ScreenRuleRestoring
    private let maintenance: @Sendable () -> Bool
    private let queue = DispatchQueue(label: "com.example.faceid.broker.watchdog")
    private var timer: DispatchSourceTimer?
    private var directoryWatch: DispatchSourceFileSystemObject?

    public init(
        health: any PluginHealthChecking,
        rule: any ScreenRuleInspecting,
        restorer: any ScreenRuleRestoring,
        maintenance: @escaping @Sendable () -> Bool = { MaintenanceMarker.isActive() }
    ) {
        self.health = health
        self.rule = rule
        self.restorer = restorer
        self.maintenance = maintenance
    }

    /// One pass. Order matters: the rule is read first so an uninstalled plugin costs nothing.
    @discardableResult
    public func check() -> Outcome {
        guard rule.referencesFaceRight() else { return .notInstalled }
        if health.isHealthy() { return .healthy }
        if maintenance() { return .skippedForMaintenance }
        BrokerLog.xpc.fault("lock-screen plugin is missing or invalid while the screen-unlock rule uses it; restoring the original rule")
        if restorer.restore() {
            BrokerLog.xpc.notice("original screen-unlock rule restored; the lock screen uses the password only")
            return .restored
        }
        BrokerLog.xpc.error("could not restore the screen-unlock rule; will retry. See recovery.md")
        return .restoreFailed
    }

    /// Checks now, whenever the plugins folder changes (removal, rename), and on a timer
    /// (a damaged binary changes no folder entry).
    public func start(interval: DispatchTimeInterval = PluginWatchdog.defaultInterval) {
        queue.async { [self] in
            check()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            self.timer = timer
            watchDirectory()
        }
    }

    private func watchDirectory() {
        let fd = open(Self.pluginsDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }   // folder absent: the timer still covers it
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link, .revoke], queue: queue
        )
        source.setEventHandler { [weak self] in self?.check() }
        source.setCancelHandler { close(fd) }
        source.resume()
        directoryWatch = source
    }
}

public protocol PluginHealthChecking: Sendable {
    /// True only if SecurityAgent could load the installed plugin as we built it.
    func isHealthy() -> Bool
}

public protocol ScreenRuleInspecting: Sendable {
    func referencesFaceRight() -> Bool
}

public protocol ScreenRuleRestoring: Sendable {
    func restore() -> Bool
}

/// The bundle exists, runs on this Mac's architecture, and is intact and signed with the pinned
/// certificate under the plugin's identifier. Without pins nothing is healthy (fail closed).
public struct SignedPluginHealth: PluginHealthChecking {
    let bundleURL: URL
    let certificateSHA1: @Sendable () -> String?

    public init(
        bundleURL: URL = PluginWatchdog.pluginBundleURL,
        certificateSHA1: @escaping @Sendable () -> String? = { InstallPins.load()?.agentCertificateSHA1 }
    ) {
        self.bundleURL = bundleURL
        self.certificateSHA1 = certificateSHA1
    }

    public func isHealthy() -> Bool {
        guard let certificate = certificateSHA1(),
              Self.hasHostArchitecture(bundleURL)
        else { return false }
        let requirementText = FaceIDXPC.pinnedCertificateRequirement(
            bundleIdentifier: PluginWatchdog.pluginBundleIdentifier, certificateSHA1: certificate
        )
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        if status != errSecSuccess {
            BrokerLog.xpc.error("plugin signature check failed: \(status, privacy: .public)")
        }
        return status == errSecSuccess
    }

    static func hasHostArchitecture(_ url: URL) -> Bool {
        guard let architectures = Bundle(url: url)?.executableArchitectures?.map(\.intValue) else { return false }
        #if arch(arm64)
        return architectures.contains(NSBundleExecutableArchitectureARM64)
        #else
        return architectures.contains(NSBundleExecutableArchitectureX86_64)
        #endif
    }
}

/// Reads `system.login.screensaver` through the public Authorization API (read-only).
public struct AuthorizationRuleInspector: ScreenRuleInspecting {
    public static let screensaverRight = "system.login.screensaver"
    public static let markers = ["com.example.faceid.face", "FaceIDAuthPlugin"]

    public init() {}

    public func referencesFaceRight() -> Bool {
        var definition: CFDictionary?
        guard AuthorizationRightGet(Self.screensaverRight, &definition) == errAuthorizationSuccess,
              let definition = definition as? [String: Any]
        else { return false }
        return Self.references(definition)
    }

    static func references(_ definition: [String: Any]) -> Bool {
        let text = String(describing: definition)
        return markers.contains { text.contains($0) }
    }
}

/// Runs the installed, root-owned `uninstall.sh --restore-authdb-only` (it backs up nothing,
/// restores the original rule and removes the face right; nothing else).
public struct UninstallScriptRestorer: ScreenRuleRestoring {
    public static let scriptURL = URL(fileURLWithPath: "/Library/Application Support/FaceID/uninstall.sh")
    public static let arguments = ["--restore-authdb-only"]
    let scriptURL: URL

    public init(scriptURL: URL = UninstallScriptRestorer.scriptURL) {
        self.scriptURL = scriptURL
    }

    public func restore() -> Bool {
        // Root-owned and writable by nobody else, like the broker binary itself.
        guard InstallPins.isRootProtected(scriptURL) else {
            BrokerLog.xpc.error("uninstall.sh is missing or not root-protected; not running it")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path] + Self.arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// Written by install.sh while it replaces the plugin, so the watchdog does not undo a
/// reinstall halfway. Trusted only if root-protected and recent (a crashed install cannot
/// switch the watchdog off for good).
public enum MaintenanceMarker {
    public static let url = URL(fileURLWithPath: "/Library/Application Support/FaceID/state/maintenance")
    public static let maximumAge: TimeInterval = 600

    public static func isActive(
        url: URL = url,
        now: Date = Date(),
        isRootProtected: (URL) -> Bool = InstallPins.isRootProtected
    ) -> Bool {
        guard isRootProtected(url),
              let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return false }
        let age = now.timeIntervalSince(modified)
        return age >= 0 && age < maximumAge
    }
}
