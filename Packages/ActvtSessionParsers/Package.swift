// swift-tools-version:6.0
import PackageDescription

// Reading AI coding agents' sessions from disk: the Claude Code, Codex and Pi
// locators and transcript parsers, the session models, the line reader and the
// watchers. Shared by the Actvt app, `actvt-cli` (through ActvtSessionsKit) and
// the open-source `privacy-scan` (through ActvtPrivacyScan). Foundation-only:
// FSEvents watching is compiled in only where CoreServices exists, `os.log` is
// shimmed elsewhere (see Compat/), and there is no networking code. No
// dependencies: zstd's decoder (BSD) is vendored as CZstd, to read the
// `.jsonl.zst` rollouts the Codex desktop app compresses old sessions into
// (Sources/CZstd/README.md).
let package = Package(
    name: "ActvtSessionParsers",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "ActvtSessionParsers", targets: ["ActvtSessionParsers"]),
    ],
    targets: [
        .target(
            name: "CZstd",
            exclude: ["LICENSE", "README.md"],
            sources: ["common", "decompress"],
            publicHeadersPath: ".",
            cSettings: [.define("ZSTD_DISABLE_ASM")]
        ),
        .target(
            name: "ActvtSessionParsers",
            dependencies: ["CZstd"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ActvtSessionParsersTests",
            dependencies: ["ActvtSessionParsers"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
