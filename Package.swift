// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MiscKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    dependencies: [
        // 自动更新框架。Sparkle 2 对无 Apple 证书分发是官方支持的：
        // 更新包经 EdDSA 通道校验即可安装（SUUpdateValidator: "adhoc signing can be used at minimum"），
        // 所以 CI 出包可以全程 ad-hoc，不需要把任何 Apple 证书搬上 GitHub Actions。
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .target(
            name: "MiscKitCore",
            path: "Sources/MiscKitCore",
            resources: [.process("Resources")],
            swiftSettings: [.enableUpcomingFeature("InternalImportsByExports")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "MiscKit",
            dependencies: ["MiscKitCore", "Sparkle"],
            path: "Sources/MiscKit",
            // Sparkle.framework 进 .app 时放 Contents/Frameworks/（由 make-app.sh 拷贝），
            // 主二进制默认只有 @loader_path（MacOS/），补上这条才能在组装好的 .app 里找到 framework。
            // unsafeFlags 会限制本包不能被下游依赖——终态应用无妨。
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "MiscKitCoreTests",
            dependencies: ["MiscKitCore"],
            path: "Tests/MiscKitCoreTests"
        ),
    ]
)
