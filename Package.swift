// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FaceID",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FaceIDCore", targets: ["FaceIDCore"]),
        .executable(name: "FaceIDAgent", targets: ["FaceIDAgent"]),
        .executable(name: "FaceIDApp", targets: ["FaceIDApp"]),
        .executable(name: "FaceIDBroker", targets: ["FaceIDBroker"]),
    ],
    targets: [
        .target(name: "FaceIDCore"),
        .target(
            name: "FaceIDAgentKit",
            dependencies: ["FaceIDCore"],
            path: "Apps/FaceIDAgent/Sources/FaceIDAgentKit"
        ),
        .executableTarget(
            name: "FaceIDAgent",
            dependencies: ["FaceIDAgentKit", "FaceIDCore"],
            path: "Apps/FaceIDAgent/Sources/FaceIDAgent",
            linkerSettings: [
                // A bare executable needs an embedded Info.plist (NSCameraUsageDescription) for TCC.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Apps/FaceIDAgent/Info.plist",
                ]),
            ]
        ),
        .target(
            name: "FaceIDAppKit",
            dependencies: ["FaceIDCore"],
            path: "Apps/FaceIDApp/Sources/FaceIDAppKit"
        ),
        .executableTarget(
            name: "FaceIDApp",
            dependencies: ["FaceIDAppKit", "FaceIDCore"],
            path: "Apps/FaceIDApp/Sources/FaceIDApp"
        ),
        .target(
            name: "FaceIDBrokerKit",
            dependencies: ["FaceIDCore"],
            path: "Apps/FaceIDBroker/Sources/FaceIDBrokerKit"
        ),
        .executableTarget(
            name: "FaceIDBroker",
            dependencies: ["FaceIDBrokerKit", "FaceIDCore"],
            path: "Apps/FaceIDBroker/Sources/FaceIDBroker"
        ),
        .testTarget(name: "FaceIDCoreTests", dependencies: ["FaceIDCore"]),
        .testTarget(name: "FaceIDAgentKitTests", dependencies: ["FaceIDAgentKit", "FaceIDBrokerKit", "FaceIDCore"]),
        .testTarget(name: "FaceIDBrokerKitTests", dependencies: ["FaceIDBrokerKit", "FaceIDCore"]),
        .testTarget(name: "FaceIDAppKitTests", dependencies: ["FaceIDAppKit", "FaceIDCore"]),
    ]
)
