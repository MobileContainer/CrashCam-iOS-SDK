// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "CrashCam-iOS",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "CrashCam-iOS",
            targets: ["CrashCam"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/microsoft/plcrashreporter.git",
            .upToNextMajor(from: "1.12.2")
        )
    ],
    targets: [
        .target(
            name: "CrashCam",
            dependencies: [
                .product(name: "CrashReporter", package: "plcrashreporter"),
                "CrashCamTouchSynthesis"
            ]
        ),
        // Debug-only private-API touch synthesis for the in-process replayer.
        // Separate target because SPM cannot mix Swift and ObjC in one.
        // Compiles to nothing in Release: the sources are #if DEBUG–guarded
        // and DEBUG is only defined for debug configurations (SPM defines it
        // automatically for Swift targets but not for C-family ones).
        .target(
            name: "CrashCamTouchSynthesis",
            publicHeadersPath: "include",
            cSettings: [
                .define("DEBUG", to: "1", .when(configuration: .debug))
            ]
        )
    ]
)
