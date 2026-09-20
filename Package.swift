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
            dependencies: ["ObjCSupport", "TranscribeCppFramework"],
            path: "AutoRec",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Vision"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("UniformTypeIdentifiers"),
                // CTranscribe is a binary framework. SwiftPM builds a bare
                // executable and has no idea an .app bundle is coming, so the
                // runtime search path that bundle.sh/release-notarized.sh will
                // need (Contents/Frameworks) has to be baked in here.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        // Handy's native ggml runtime (transcribe.cpp). It runs GigaAM-v3 GGUF —
        // Sber's Russian ASR model — on Metal/CPU without dragging in Python,
        // PyTorch or ONNX Runtime. The whole framework is 14 MB.
        // подход из amanu (MIT, gsamat/amanu): Package.swift, binaryTarget TranscribeCppFramework
        .binaryTarget(
            name: "TranscribeCppFramework",
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.2.0/TranscribeCpp.xcframework.zip",
            checksum: "5fffd4557d561ab6e45edd2445978682a513c1cd030c5a330c8519c5b27b64d9"
        ),
    ]
)
