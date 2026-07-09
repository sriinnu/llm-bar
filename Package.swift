// swift-tools-version:5.9
//
// SakshiBar — macOS menubar witness for your local LLM models
// (llama.cpp/lcp, Ollama, Hugging Face cache).
//
// Quick start:
//   swift build -c release        # build only
//   ./bundle.sh                   # build + ad-hoc bundle (dev)
//   ./bundle.sh --signed          # Developer ID signed (needs DEV_ID env)
//   ./bundle.sh --release         # signed + notarized + appcast (full release)
//
// Auto-updates are powered by Sparkle 2.x. See RELEASE.md for the full
// release flow including notarization and appcast signing.

import PackageDescription

let package = Package(
    name: "SakshiBar",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "SakshiBar", targets: ["SakshiBar"]),
    ],
    dependencies: [
        // Sparkle 2.x — auto-update framework for macOS apps.
        // Pinned to the 2.x major to avoid breaking API changes.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "SakshiBar",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/SakshiBar",
            resources: [.copy("Resources")]
        )
    ]
)
