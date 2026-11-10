// swift-tools-version:6.0
import PackageDescription

// The on-device secrets and personal-data scanner, shared by the Actvt app and
// the standalone `privacy-scan` CLI. It reads transcripts through
// ActvtSessionParsers, so it scans exactly the sessions and text the app does.
// Foundation-only, with no third-party dependencies and no networking code: it
// builds on macOS and Linux, and everything it reads stays on the machine. The
// app's AI detector (onnxruntime and a downloaded model) stays in the app and
// plugs in through `PIIDetector`.
let package = Package(
    name: "ActvtPrivacyScan",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "ActvtPrivacyScan", targets: ["ActvtPrivacyScan"]),
        .executable(name: "privacy-scan", targets: ["PrivacyScanCLI"]),
    ],
    dependencies: [
        .package(path: "../ActvtSessionParsers"),
    ],
    targets: [
        .target(
            name: "ActvtPrivacyScan",
            dependencies: ["ActvtSessionParsers"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "PrivacyScanCLI",
            dependencies: ["ActvtPrivacyScan", "ActvtSessionParsers"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ActvtPrivacyScanTests",
            dependencies: ["ActvtPrivacyScan", "ActvtSessionParsers"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
