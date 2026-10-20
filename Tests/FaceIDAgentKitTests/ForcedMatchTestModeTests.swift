import FaceIDCore
import Foundation
import Testing
@testable import FaceIDAgentKit

/// Static checks that the VM-only forced-match mode can never reach a release build or a real Mac.
struct ForcedMatchTestModeContractTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let marker = "FACEID-FORCED-MATCH-VM-TEST"

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func sourceIsDebugOnly() throws {
        let source = try Self.read("Apps/FaceIDAgent/Sources/FaceIDAgentKit/ForcedMatchTestMode.swift")
        #expect(source.hasPrefix("#if DEBUG\n"))
        #expect(source.hasSuffix("#endif\n"))
        #expect(source.components(separatedBy: "#endif").count == 2, "the whole file must sit in one #if DEBUG block")
        #expect(source.contains(#"marker = "\#(Self.marker)""#))
    }

    @Test func runtimeWiresItOnlyInDebug() throws {
        let runtime = try Self.read("Apps/FaceIDAgent/Sources/FaceIDAgentKit/AgentRuntime.swift")
        let use = try #require(runtime.range(of: "ForcedMatchTestAuthenticator("))
        let open = try #require(runtime.range(of: "#if DEBUG", options: .backwards, range: runtime.startIndex..<use.lowerBound))
        let close = try #require(runtime.range(of: "#endif", range: use.upperBound..<runtime.endIndex))
        #expect(!runtime[open.upperBound..<use.lowerBound].contains("#endif"))
        #expect(close.lowerBound > use.upperBound)
        // Only the agent may contain it: never the broker, the app or the core library.
        for directory in ["Sources", "Apps/FaceIDBroker", "Apps/FaceIDApp", "Plugins"] {
            let enumerator = FileManager.default.enumerator(at: Self.root.appendingPathComponent(directory), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard ["swift", "m", "h", "c"].contains(url.pathExtension) else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                #expect(!text.contains("ForcedMatch"), "\(url.lastPathComponent) must not reference the test mode")
            }
        }
    }

    @Test func releaseBuildRefusesTheMarker() throws {
        let build = try Self.read("Scripts/build-app.sh")
        #expect(build.contains(#"FORCED_MATCH_MARKER="\#(Self.marker)""#))
        #expect(build.contains(#"grep -aq "$FORCED_MATCH_MARKER" "$DIST/FaceIDAgent""#))
        #expect(build.contains(#"if [[ "$CONFIGURATION" == "release" ]]; then"#))
    }

    @Test func installRefusesDebugBuildsOutsideAVM() throws {
        let install = try Self.read("Scripts/install.sh")
        #expect(install.contains(#"readonly FORCED_MATCH_MARKER="\#(Self.marker)""#))
        let check = try #require(install.range(of: #"grep -aq "$FORCED_MATCH_MARKER" "$DIST/FaceIDAgent""#))
        let tail = install[check.upperBound...]
        let vm = try #require(tail.range(of: "kern.hv_vmm_present"))
        let refuse = try #require(tail.range(of: "|| die "))
        #expect(vm.lowerBound < refuse.lowerBound)
        // Not overridable by --allow-host: the check must not mention it.
        let fi = try #require(tail.range(of: "\nfi\n"))
        #expect(!tail[..<fi.lowerBound].contains("allow_host"))
        // Before anything on the system changes.
        let firstChange = try #require(install.range(of: "install -d -o root -g wheel -m 755 \"$SUPPORT\""))
        #expect(check.lowerBound < firstChange.lowerBound)
    }

    @Test func flagLivesWhereUninstallCleansUp() {
        // uninstall.sh removes everything in the support folder except backups.
        #expect(ForcedMatchTestMode.flagURL.deletingLastPathComponent() == InstallPins.defaultURL.deletingLastPathComponent())
    }
}

#if DEBUG
struct ForcedMatchTestModeTests {
    private let flag = URL(fileURLWithPath: "/nonexistent/force-match-vm-test")

    @Test func needsBothVirtualMachineAndRootOwnedFlag() {
        #expect(!ForcedMatchTestMode.isActive(flagURL: flag, isVirtualMachine: false, isRootProtected: { _ in true }))
        #expect(!ForcedMatchTestMode.isActive(flagURL: flag, isVirtualMachine: true, isRootProtected: { _ in false }))
        #expect(!ForcedMatchTestMode.isActive(flagURL: flag, isVirtualMachine: false, isRootProtected: { _ in false }))
        #expect(ForcedMatchTestMode.isActive(flagURL: flag, isVirtualMachine: true, isRootProtected: { _ in true }))
    }

    @Test func userOwnedFlagIsIgnored() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("force-match-\(UUID().uuidString)")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!ForcedMatchTestMode.isActive(flagURL: url, isVirtualMachine: true))
    }

    @Test func missingFlagIsIgnored() {
        #expect(!ForcedMatchTestMode.isActive(flagURL: flag, isVirtualMachine: true))
    }

    @Test func realMacIsNotDetectedAsVirtualMachineByTheDefaultGate() {
        // The real flag file is never created outside a VM, so the default gate is off here.
        if !ForcedMatchTestMode.runningInVirtualMachine() {
            #expect(!ForcedMatchTestMode.isActive())
        }
    }

    @Test func activeAnswersMatchWithoutScanning() async {
        let real = MockAuthenticator(outcome: .noMatch)
        let authenticator = ForcedMatchTestAuthenticator(wrapped: real, isActive: { true })
        #expect(await authenticator.authenticate() == .match)
        #expect(await real.calls == 0)
    }

    @Test func inactiveRunsTheRealScan() async {
        let real = MockAuthenticator(outcome: .noMatch)
        let authenticator = ForcedMatchTestAuthenticator(wrapped: real, isActive: { false })
        #expect(await authenticator.authenticate() == .noMatch)
        #expect(await real.calls == 1)
    }

    @Test func lockoutAndResetPassThrough() async {
        let real = MockAuthenticator()
        await real.setLockedOut(true)
        let authenticator = ForcedMatchTestAuthenticator(wrapped: real, isActive: { true })
        #expect(await authenticator.isLockedOut)
        await authenticator.resetAfterPasswordAuthentication()
        #expect(await real.resets == 1)
    }

    @Test func disabledSwitchStillWins() async {
        let coordinator = makeCoordinator(
            settings: MockSettings(enabled: false),
            authenticator: MockAuthenticator(outcome: .match)
        )
        #expect(await coordinator.authenticate(requestKey: "k") == .error(.disabled))
    }
}
#endif
