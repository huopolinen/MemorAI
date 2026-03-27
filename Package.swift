// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MemorAI",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MemorAI",
            path: "AutoRec",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Vision"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
    ]
)
