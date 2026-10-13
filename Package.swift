// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DeejMac",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "DeejMac",
            path: "Sources/DeejMac",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        )
    ]
)
