import Foundation
import Testing

/// Static guards that keep biometric data inside the agent process (CLAUDE.md §7).
/// They scan production sources, so a future change that adds networking, disk writes,
/// console output or a data-carrying XPC method fails the build's tests.
struct PrivacyGuardTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct SourceLine {
        let file: String
        let number: Int
        let text: String
    }

    private static func productionSources() throws -> [(name: String, text: String)] {
        var result: [(String, String)] = []
        for directory in ["Sources", "Apps"] {
            let base = packageRoot.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relative = String(url.path.dropFirst(packageRoot.path.count + 1))
                result.append((relative, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return result
    }

    /// Code lines only (comment lines are skipped so docs may name forbidden APIs).
    private static func codeLines() throws -> [SourceLine] {
        try productionSources().flatMap { file in
            file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { return nil }
                return SourceLine(file: file.name, number: index + 1, text: String(line))
            }
        }
    }

    private func violations(_ patterns: [String], allowedIn allowed: Set<String> = []) throws -> [String] {
        let regexes = try patterns.map { try NSRegularExpression(pattern: $0) }
        return try Self.codeLines().compactMap { line in
            guard !allowed.contains((line.file as NSString).lastPathComponent) else { return nil }
            let range = NSRange(line.text.startIndex..., in: line.text)
            guard regexes.contains(where: { $0.firstMatch(in: line.text, range: range) != nil }) else { return nil }
            return "\(line.file):\(line.number): \(line.text.trimmingCharacters(in: .whitespaces))"
        }
    }

    @Test func sourcesWereFound() throws {
        #expect(try Self.productionSources().count > 10)
    }

    @Test func noNetworking() throws {
        let found = try violations([
            #"\bURLSession\b"#, #"\bURLRequest\b"#, #"import\s+Network\b"#, #"\bNW(Connection|Listener|Browser)\b"#,
            #"\bCFSocket"#, #"\bCFStream"#, #"\bsocket\("#, #"\bconnect\("#, #"\bWKWebView\b"#,
            #"\bMultipeerConnectivity\b"#,
        ], allowedIn: ["NetworkLockdown.swift"])
        #expect(found.isEmpty, "networking code found:\n\(found.joined(separator: "\n"))")
    }

    @Test func noImageOrRawDataWrites() throws {
        let found = try violations([
            #"\bCGImageDestination"#, #"jpegData|pngData|heicData"#, #"representation\(using"#,
            #"\.write\(to"#, #"FileHandle\(forWriting"#, #"createFile\("#, #"AVAssetWriter"#, #"AVCaptureMovieFileOutput"#,
            #"AVCapturePhotoOutput"#,
        ])
        #expect(found.isEmpty, "disk write code found:\n\(found.joined(separator: "\n"))")
    }

    @Test func noConsoleOutput() throws {
        let found = try violations([#"(^|[^.\w])print\("#, #"\bdebugPrint\("#, #"\bNSLog\("#, #"(^|[^.\w])dump\("#])
        #expect(found.isEmpty, "console output found:\n\(found.joined(separator: "\n"))")
    }

    @Test func preferencesOnlyHoldTheOnOffSwitch() throws {
        let found = try violations([#"\bUserDefaults\b"#, #"\bNSUbiquitousKeyValueStore\b"#, #"\bCKContainer\b"#],
                                   allowedIn: ["AgentSettings.swift", "AgentRuntime.swift", "AppSettings.swift"])
        #expect(found.isEmpty, "preferences / iCloud use found:\n\(found.joined(separator: "\n"))")
    }

    @Test func biometricValuesAreNeverLoggedPublicly() throws {
        let logLines = try Self.codeLines().filter { $0.text.contains("Log.") && $0.text.contains(#"\("#) }
        let leaking = logLines.filter { line in
            let lower = line.text.lowercased()
            let mentionsBiometric = ["embedding", "vector", "similarity", "score", "template", "pixel", "frame"]
                .contains { lower.contains("\\(" + $0) || lower.contains("\\(probe") }
            return mentionsBiometric && !line.text.contains("privacy: .private")
        }
        #expect(leaking.isEmpty, "biometric values in logs:\n\(leaking.map { "\($0.file):\($0.number)" }.joined(separator: "\n"))")
    }

    @Test func xpcProtocolCarriesNoBiometricTypes() throws {
        let url = Self.packageRoot.appendingPathComponent("Sources/FaceIDCore/XPC/FaceIDServiceProtocol.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(text.range(of: "@objc(FaceIDServiceProtocol) public protocol FaceIDServiceProtocol"))
        let end = try #require(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex))
        let body = text[start.lowerBound..<end.upperBound]
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        for forbidden in [#"\bData\b"#, #"\bNSData\b"#, #"\[Float\]"#, #"\[Double\]"#, #"\bFloat\b"#,
                          #"Embedding"#, #"Template"#, #"PixelBuffer"#, #"CGImage"#, #"NSImage"#, #"NSArray"#] {
            #expect(body.range(of: forbidden, options: .regularExpression) == nil, "XPC protocol exposes \(forbidden)")
        }
    }

    @Test func menuBarAppNeverTouchesCameraOrModels() throws {
        let appFiles = try Self.productionSources().filter { $0.name.hasPrefix("Apps/FaceIDApp/") }
        #expect(!appFiles.isEmpty)
        for file in appFiles {
            for framework in ["AVFoundation", "Vision", "CoreML", "CoreImage", "ScreenCaptureKit"] {
                #expect(!file.text.contains("import \(framework)"), "\(file.name) imports \(framework)")
            }
            #expect(!file.text.contains("CameraService"), "\(file.name) uses the camera")
        }
        let info = try String(contentsOf: Self.packageRoot.appendingPathComponent("Apps/FaceIDApp/Info.plist"), encoding: .utf8)
        #expect(!info.contains("<key>NSCameraUsageDescription</key>"))
        let entitlements = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: Self.packageRoot.appendingPathComponent("Apps/FaceIDApp/FaceIDApp.entitlements")), format: nil
        ) as? [String: Any])
        #expect(entitlements.isEmpty)
    }

    /// The broker runs as root and must never see biometric data: no camera, models or templates.
    @Test func brokerNeverTouchesBiometricData() throws {
        let brokerFiles = try Self.productionSources().filter { $0.name.hasPrefix("Apps/FaceIDBroker/") }
        #expect(!brokerFiles.isEmpty)
        for file in brokerFiles {
            for forbidden in ["import AVFoundation", "import Vision", "import CoreML", "import CoreImage",
                              "CameraService", "FaceDetector", "EmbeddingModel", "FaceEmbedding", "TemplateStore",
                              "EnrolledTemplate", "SecItem", "UserDefaults"] {
                #expect(!file.text.contains(forbidden), "\(file.name) contains \(forbidden)")
            }
        }
        let entitlements = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: Self.packageRoot.appendingPathComponent("Apps/FaceIDBroker/FaceIDBroker.entitlements")), format: nil
        ) as? [String: Any])
        #expect(entitlements.isEmpty)
    }

    @Test func brokerDaemonRunsInsideNoNetworkSandbox() throws {
        let plistURL = Self.packageRoot.appendingPathComponent("LaunchDaemons/com.example.faceid.broker.plist")
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        let arguments = try #require(plist["ProgramArguments"] as? [String])
        #expect(arguments.first == "/usr/bin/sandbox-exec")
        let profile = try String(contentsOf: Self.packageRoot.appendingPathComponent("Apps/FaceIDBroker/broker.sb"), encoding: .utf8)
        let rules = profile.split(separator: "\n").filter { !$0.hasPrefix(";") }.joined(separator: "\n")
        #expect(rules.contains("(deny network*)"))
        #expect(!rules.contains("(allow network"))
    }

    @Test func launchAgentRunsInsideNoNetworkSandbox() throws {
        let plistURL = Self.packageRoot.appendingPathComponent("LaunchAgents/com.example.faceid.agent.plist")
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        let arguments = try #require(plist["ProgramArguments"] as? [String])
        #expect(arguments.first == "/usr/bin/sandbox-exec")
        #expect(arguments.contains("-f"))

        let profile = try String(contentsOf: Self.packageRoot.appendingPathComponent("Apps/FaceIDAgent/agent.sb"), encoding: .utf8)
        let rules = profile.split(separator: "\n").filter { !$0.hasPrefix(";") }.joined(separator: "\n")
        #expect(rules.contains("(deny network*)"))
        #expect(!rules.contains("(allow network"))
    }

    @Test func agentEntitlementsAreMinimal() throws {
        let url = Self.packageRoot.appendingPathComponent("Apps/FaceIDAgent/FaceIDAgent.entitlements")
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(Set(plist.keys) == ["com.apple.security.device.camera"], "unexpected entitlements: \(plist.keys.sorted())")
    }
}
