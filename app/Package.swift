// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Strip",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "StripCore"),
        .executableTarget(
            name: "Strip",
            dependencies: ["StripCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                // Sparkle.framework is embedded in Strip.app/Contents/Frameworks by scripts/bundle.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "StripCoreTests", dependencies: ["StripCore"]),
    ]
)
