// swift-tools-version:6.0
import PackageDescription

// Agent-session discovery shared between the Actvt app, the embedded macOS
// `actvt-cli`, and the standalone Linux CLI builds (Static Linux SDK). The
// library is Foundation-only by design: FSEvents watching is compiled in only
// where CoreServices exists, `os.log` is shimmed elsewhere (see Compat/), and
// GRDB/AppKit never enter — metrics indexing and UI stay in the app.
let package = Package(
    name: "ActvtSessionsKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "ActvtSessionsKit", targets: ["ActvtSessionsKit"]),
        .executable(name: "actvt-cli", targets: ["ActvtCLI"]),
    ],
    targets: [
        .target(
            name: "ActvtSessionsKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ActvtCLI",
            dependencies: ["ActvtSessionsKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ActvtSessionsKitTests",
            dependencies: ["ActvtSessionsKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
