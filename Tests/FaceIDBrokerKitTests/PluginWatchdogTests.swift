@testable import FaceIDCore
import Foundation
import Testing
@testable import FaceIDBrokerKit

final class FakeWatchdogParts: PluginHealthChecking, ScreenRuleInspecting, ScreenRuleRestoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _healthy: Bool
    private var _ruleUsesPlugin: Bool
    private var _restoreSucceeds: Bool
    private var _restores = 0
    private var _healthChecks = 0

    init(healthy: Bool, ruleUsesPlugin: Bool, restoreSucceeds: Bool = true) {
        _healthy = healthy
        _ruleUsesPlugin = ruleUsesPlugin
        _restoreSucceeds = restoreSucceeds
    }

    var restores: Int { lock.withLock { _restores } }
    var healthChecks: Int { lock.withLock { _healthChecks } }
    func setRestoreSucceeds(_ value: Bool) { lock.withLock { _restoreSucceeds = value } }

    func isHealthy() -> Bool { lock.withLock { _healthChecks += 1; return _healthy } }
    func referencesFaceRight() -> Bool { lock.withLock { _ruleUsesPlugin } }
    func restore() -> Bool {
        lock.withLock {
            _restores += 1
            if _restoreSucceeds { _ruleUsesPlugin = false }
            return _restoreSucceeds
        }
    }
}

struct PluginWatchdogTests {
    private func watchdog(_ parts: FakeWatchdogParts, maintenance: Bool = false) -> PluginWatchdog {
        PluginWatchdog(health: parts, rule: parts, restorer: parts, maintenance: { maintenance })
    }

    @Test func doesNothingWhenTheRuleDoesNotUseThePlugin() {
        let parts = FakeWatchdogParts(healthy: false, ruleUsesPlugin: false)
        #expect(watchdog(parts).check() == .notInstalled)
        #expect(parts.restores == 0)
        #expect(parts.healthChecks == 0, "no signature work when nothing is installed")
    }

    @Test func leavesAHealthyPluginAlone() {
        let parts = FakeWatchdogParts(healthy: true, ruleUsesPlugin: true)
        #expect(watchdog(parts).check() == .healthy)
        #expect(parts.restores == 0)
    }

    @Test func restoresTheRuleWhenThePluginIsBroken() {
        let parts = FakeWatchdogParts(healthy: false, ruleUsesPlugin: true)
        let dog = watchdog(parts)
        #expect(dog.check() == .restored)
        #expect(parts.restores == 1)
        // Afterwards the rule no longer uses the plugin: nothing more to do.
        #expect(dog.check() == .notInstalled)
        #expect(parts.restores == 1)
    }

    @Test func retriesAFailedRestore() {
        let parts = FakeWatchdogParts(healthy: false, ruleUsesPlugin: true, restoreSucceeds: false)
        let dog = watchdog(parts)
        #expect(dog.check() == .restoreFailed)
        parts.setRestoreSucceeds(true)
        #expect(dog.check() == .restored)
        #expect(parts.restores == 2)
    }

    @Test func waitsWhileInstallReplacesThePlugin() {
        let parts = FakeWatchdogParts(healthy: false, ruleUsesPlugin: true)
        #expect(watchdog(parts, maintenance: true).check() == .skippedForMaintenance)
        #expect(parts.restores == 0)
    }

    @Test func startChecksImmediately() async throws {
        let parts = FakeWatchdogParts(healthy: false, ruleUsesPlugin: true)
        watchdog(parts).start(interval: .seconds(3600))
        for _ in 0..<100 where parts.restores == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(parts.restores == 1)
    }

    // MARK: Real parts, without touching the system

    @Test func missingBundleIsUnhealthy() {
        let health = SignedPluginHealth(bundleURL: URL(fileURLWithPath: "/nonexistent/FaceIDAuthPlugin.bundle"),
                                        certificateSHA1: { String(repeating: "A", count: 40) })
        #expect(!health.isHealthy())
    }

    @Test func noPinsMeansUnhealthy() {
        let health = SignedPluginHealth(bundleURL: PluginWatchdog.pluginBundleURL, certificateSHA1: { nil })
        #expect(!health.isHealthy())
    }

    @Test func ruleInspectorRecognisesOurRule() {
        #expect(AuthorizationRuleInspector.references(["class": "rule", "k-of-n": 1,
                                                       "rule": ["com.example.faceid.face", "authenticate-session-owner-or-admin"]]))
        #expect(!AuthorizationRuleInspector.references(["class": "rule", "rule": ["use-login-window-ui"]]))
    }

    @Test func restorerRefusesAScriptThatIsNotRootOwned() throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-\(UUID().uuidString).sh")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: script)
        defer { try? FileManager.default.removeItem(at: script) }
        #expect(!UninstallScriptRestorer(scriptURL: script).restore())
    }

    @Test func maintenanceMarkerMustBeRootOwnedAndRecent() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("maintenance-\(UUID().uuidString)")
        try Data().write(to: marker)
        defer { try? FileManager.default.removeItem(at: marker) }
        #expect(!MaintenanceMarker.isActive(url: marker), "a user-owned marker is ignored")
        #expect(MaintenanceMarker.isActive(url: marker, isRootProtected: { _ in true }))
        let later = Date().addingTimeInterval(MaintenanceMarker.maximumAge + 1)
        #expect(!MaintenanceMarker.isActive(url: marker, now: later, isRootProtected: { _ in true }), "stale marker")
        #expect(!MaintenanceMarker.isActive(url: URL(fileURLWithPath: "/nonexistent/maintenance"), isRootProtected: { _ in true }))
    }
}

/// Static checks: the broker may only restore the original rule, through uninstall.sh.
struct PluginWatchdogContractTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func brokerOnlyRunsTheRestoreOnlyUninstall() throws {
        let source = try Self.read("Apps/FaceIDBroker/Sources/FaceIDBrokerKit/PluginWatchdog.swift")
        #expect(UninstallScriptRestorer.arguments == ["--restore-authdb-only"])
        #expect(UninstallScriptRestorer.scriptURL.path == "/Library/Application Support/FaceID/uninstall.sh")
        // Code only (comments may explain the rule).
        let code = source.split(separator: "\n").map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
        for forbidden in ["authorizationdb", "AuthorizationRightSet", "AuthorizationRightRemove"] {
            #expect(!code.contains(forbidden), "broker code must not change rules itself: \(forbidden)")
        }
        let uninstall = try Self.read("Scripts/uninstall.sh")
        #expect(uninstall.contains("--restore-authdb-only) restore_only=true"))
    }

    @Test func pathsMatchTheScripts() throws {
        let install = try Self.read("Scripts/install.sh")
        let uninstall = try Self.read("Scripts/uninstall.sh")
        #expect(install.contains(#"readonly PLUGIN_DEST="/Library/Security/SecurityAgentPlugins/$PLUGIN_NAME""#))
        #expect(install.contains(#"readonly PLUGIN_NAME="FaceIDAuthPlugin.bundle""#))
        #expect(uninstall.contains(#"PLUGIN_DEST="\#(PluginWatchdog.pluginBundleURL.path)""#))
        #expect(install.contains(#"readonly MAINTENANCE_MARKER="$STATE_DIR/maintenance""#))
        #expect(MaintenanceMarker.url.path == "/Library/Application Support/FaceID/state/maintenance")
        let build = try Self.read("Scripts/build-plugin.sh")
        #expect(build.contains("--identifier \(PluginWatchdog.pluginBundleIdentifier)"))
    }

    @Test func installMarksMaintenanceAroundThePluginSwap() throws {
        let install = try Self.read("Scripts/install.sh")
        func offset(_ needle: String) throws -> Int {
            let range = try #require(install.range(of: needle), "missing: \(needle)")
            return install.distance(from: install.startIndex, to: range.lowerBound)
        }
        let mark = try offset(#"touch "$MAINTENANCE_MARKER""#)
        let swap = try offset(#"\#n    rm -rf "$PLUGIN_DEST"\#n    ditto"#)
        let unmark = try offset(#"    rm -f "$MAINTENANCE_MARKER"\#n    log "lock-screen plugin installed""#)
        #expect(mark < swap && swap < unmark)
        // A failed install clears it too, so the watchdog is never paused for long.
        let rollback = try offset("rollback() {")
        let rollbackEnd = try offset("trap rollback EXIT")
        let inRollback = install[install.index(install.startIndex, offsetBy: rollback)..<install.index(install.startIndex, offsetBy: rollbackEnd)]
        #expect(inRollback.contains(#"rm -f "$MAINTENANCE_MARKER""#))
    }

    @Test func runtimeStartsTheWatchdogFirst() throws {
        let runtime = try Self.read("Apps/FaceIDBroker/Sources/FaceIDBrokerKit/BrokerRuntime.swift")
        let start = try #require(runtime.range(of: "watchdog.start()"))
        let listen = try #require(runtime.range(of: "agentListener.resume()"))
        #expect(start.lowerBound < listen.lowerBound)
        #expect(runtime.contains("health: SignedPluginHealth()"))
    }
}
