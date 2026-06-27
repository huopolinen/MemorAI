// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MemorAI",
    platforms: [.macOS(.v14)],
    targets: [
        // Tiny Objective-C shim so Swift can catch NSExceptions raised by
        // AVFoundation (which Swift's try/catch cannot). See ObjCSupport.h.
        .target(
            name: "ObjCSupport",
            path: "ObjCSupport"
        ),
        .executableTarget(
            name: "MemorAI",
            dependencies: ["ObjCSupport"],
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
