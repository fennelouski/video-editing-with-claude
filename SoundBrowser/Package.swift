// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClautoSoundBrowser",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SoundBrowserCore", targets: ["SoundBrowserCore"]),
        .library(name: "SoundBrowserUI", targets: ["SoundBrowserUI"]),
        .executable(name: "ClautoSoundBrowser", targets: ["ClautoSoundBrowser"])
    ],
    targets: [
        .target(name: "SoundBrowserCore", resources: [.copy("Resources")]),
        .target(name: "SoundBrowserUI", dependencies: ["SoundBrowserCore"]),
        .executableTarget(name: "ClautoSoundBrowser", dependencies: ["SoundBrowserUI", "SoundBrowserCore"]),
        .testTarget(name: "SoundBrowserTests", dependencies: ["SoundBrowserCore"])
    ],
    swiftLanguageModes: [.v5]
)
