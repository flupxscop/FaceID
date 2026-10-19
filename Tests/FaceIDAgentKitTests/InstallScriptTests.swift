import FaceIDBrokerKit
import FaceIDCore
import Foundation
import Testing
@testable import FaceIDAgentKit

/// Static checks on Scripts/install.sh and Scripts/uninstall.sh. The scripts are only parsed
/// (`bash -n`), never executed — they need sudo and change the system.
struct InstallScriptTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let support = "/Library/Application Support/FaceID"

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private static func offset(of needle: String, in text: String) throws -> Int {
        let range = try #require(text.range(of: needle), "missing: \(needle)")
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    @Test(arguments: ["Scripts/install.sh", "Scripts/uninstall.sh", "Scripts/build-app.sh",
                      "Scripts/build-plugin.sh", "Scripts/test-plugin.sh", "Scripts/vm-diagnose.sh"])
    func parsesWithSystemBash(script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", Self.root.appendingPathComponent(script).path]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test(arguments: ["Scripts/install.sh", "Scripts/uninstall.sh", "Scripts/build-app.sh",
                      "Scripts/build-plugin.sh", "Scripts/test-plugin.sh", "Scripts/vm-diagnose.sh"])
    func avoidsBash4Features(script: String) throws {
        let text = try Self.read(script)
        for feature in ["declare -A", "mapfile", "readarray", ",,}", "^^}", "|&", "&>>"] {
            #expect(!text.contains(feature), "\(script) uses \(feature), unavailable in /bin/bash 3.2")
        }
        #expect(text.hasPrefix("#!/bin/bash\n"))
    }

    @Test func pathsMatchLaunchAgentAndConfiguration() throws {
        for script in ["Scripts/install.sh", "Scripts/uninstall.sh"] {
            #expect(try Self.read(script).contains(#"readonly SUPPORT="\#(Self.support)""#), "\(script)")
        }
        let plist = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: Self.root.appendingPathComponent("LaunchAgents/com.example.faceid.agent.plist")), format: nil
        ) as? [String: Any])
        let arguments = try #require(plist["ProgramArguments"] as? [String])
        #expect(arguments == ["/usr/bin/sandbox-exec", "-f", "\(Self.support)/agent.sb", "\(Self.support)/FaceIDAgent"])
        #expect((plist["MachServices"] as? [String: Bool])?[FaceIDXPC.machServiceName] == true)
        #expect(AgentConfiguration.defaultModelURL.path == "\(Self.support)/Models/FaceEmbedding.mlmodelc")
        #expect(try Self.read("Scripts/install.sh").contains(#""$SUPPORT/Models/FaceEmbedding.mlmodelc""#))
    }

    @Test func brokerDaemonMatchesTheScriptsAndCode() throws {
        let plist = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: Self.root.appendingPathComponent("LaunchDaemons/com.example.faceid.broker.plist")), format: nil
        ) as? [String: Any])
        #expect(plist["Label"] as? String == FaceIDBrokerXPC.bundleIdentifier)
        let arguments = try #require(plist["ProgramArguments"] as? [String])
        #expect(arguments == ["/usr/bin/sandbox-exec", "-f", "\(Self.support)/broker.sb", "\(Self.support)/FaceIDBroker"])
        let services = try #require(plist["MachServices"] as? [String: Bool])
        #expect(services == [FaceIDBrokerXPC.agentServiceName: true, FaceIDBrokerXPC.authServiceName: true])
        #expect(plist["UserName"] == nil, "the broker runs as root only to own system-wide services")

        let install = try Self.read("Scripts/install.sh")
        let uninstall = try Self.read("Scripts/uninstall.sh")
        for script in [install, uninstall] {
            #expect(script.contains(#"readonly BROKER_LABEL="com.example.faceid.broker""#))
            #expect(script.contains(#"readonly LAUNCH_DAEMON="/Library/LaunchDaemons/$BROKER_LABEL.plist""#))
        }
        #expect(install.contains(#"require_signed "$DIST/FaceIDBroker" "com.example.faceid.broker""#))
        #expect(install.contains(#"*"Signature=adhoc"*"#), "the broker must be ad-hoc (verified by code hash)")
        #expect(install.contains("plutil -insert \(InstallPins.brokerCDHashKey) "))
        #expect(install.contains("plutil -insert \(InstallPins.agentCertificateKey) "))
        #expect(install.contains(#"install -o root -g wheel -m 644 "$pins_tmp" "$SUPPORT/pins.plist""#))
        #expect(InstallPins.defaultURL.path == "\(Self.support)/pins.plist")
        // pins.plist must exist before the broker and the agent start.
        let pins = try Self.offset(of: #""$SUPPORT/pins.plist""#, in: install)
        #expect(pins < (try Self.offset(of: #"reload_job system "$BROKER_LABEL" "$LAUNCH_DAEMON""#, in: install)))
        #expect(install.contains(#""$DIST/broker.sb" "$DIST/FaceIDBroker" --check-isolation"#))
        // The broker must be up before the agent tries to register (it retries, but this avoids a gap).
        let broker = try Self.offset(of: #"reload_job system "$BROKER_LABEL" "$LAUNCH_DAEMON""#, in: install)
        let agent = try Self.offset(of: #"reload_job "gui/$uid" "$AGENT_LABEL" "$LAUNCH_AGENT""#, in: install)
        #expect(broker < agent)
        // Uninstall: screen-unlock rule first, then the broker.
        let restore = try Self.offset(of: "if ! restore_authdb; then", in: uninstall)
        let stopBroker = try Self.offset(of: #"launchctl bootout "system/$BROKER_LABEL""#, in: uninstall)
        #expect(restore < stopBroker)
    }

    @Test func uninstallDeletesTheRealKeychainItems() throws {
        let uninstall = try Self.read("Scripts/uninstall.sh")
        let store = try Self.read("Sources/FaceIDCore/Storage/TemplateStore.swift")
        #expect(uninstall.contains(#"KEYCHAIN_SERVICE="\#(FaceIDConfig.keychainService)""#))
        for account in ["template", "template-key.secure-enclave", "template-key.software"] {
            #expect(store.contains(#""\#(account)""#), "TemplateStore no longer uses \(account)")
            #expect(uninstall.contains(account), "uninstall.sh does not delete \(account)")
        }
        #expect(uninstall.contains(#"PREFERENCES_DOMAIN="\#(FaceIDConfig.logSubsystem)""#))
    }

    @Test func installBacksUpBeforeAnyAuthorizationChange() throws {
        let install = try Self.read("Scripts/install.sh")
        let backup = try Self.offset(of: "security authorizationdb read \"$rule\"", in: install)
        let firstWrite = try Self.offset(of: "security authorizationdb write", in: install)
        #expect(backup < firstWrite)
        #expect(install.contains("kern.hv_vmm_present"), "plugin install must refuse outside a VM by default")
        #expect(install.contains("trap rollback EXIT"))
        #expect(install.contains(#"[[ ! -d "$BACKUP_DIR/original" ]]"#), "the original backup must never be overwritten")
    }

    @Test func uninstallRestoresRulesBeforeRemovingThePlugin() throws {
        let uninstall = try Self.read("Scripts/uninstall.sh")
        let restore = try Self.offset(of: "if ! restore_authdb; then", in: uninstall)
        let removePlugin = try Self.offset(of: #"safe_remove "$PLUGIN_DEST""#, in: uninstall)
        #expect(restore < removePlugin)
        #expect(uninstall.contains("--restore-authdb-only"))
    }

    /// CLAUDE.md §7.7: authorizationdb is modified only by install.sh / uninstall.sh.
    @Test func authorizationdbIsWrittenOnlyByTheScripts() throws {
        let allowed: Set<String> = ["Scripts/install.sh", "Scripts/uninstall.sh"]
        let excludedDirectories = [".build", "dist", ".git", ".swiftpm"]
        guard let enumerator = FileManager.default.enumerator(at: Self.root, includingPropertiesForKeys: nil) else {
            Issue.record("cannot list the repository")
            return
        }
        var offenders: [String] = []
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(Self.root.path.count + 1))
            if excludedDirectories.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) {
                enumerator.skipDescendants()
                continue
            }
            guard ["sh", "swift", "c", "h", "m", "plist", "py", "command"].contains(url.pathExtension),
                  !relative.hasPrefix("Tests/"),
                  !allowed.contains(relative),
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            if text.contains("authorizationdb write") || text.contains("authorizationdb remove")
                || text.contains("AuthorizationRightSet") || text.contains("AuthorizationRightRemove") {
                offenders.append(relative)
            }
        }
        #expect(offenders.isEmpty, "authorizationdb modified outside install/uninstall: \(offenders)")
    }
}
