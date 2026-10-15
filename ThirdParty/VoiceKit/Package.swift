// swift-tools-version: 6.0
import PackageDescription

// Nathan's existing dependency-free VoiceKit capture/recognition subset.
// No Dictate executable, network provider, updater or model dependency.
let package = Package(name: "VoiceKit", platforms: [.macOS("26.0")],
    products: [.library(name: "VoiceKit", targets: ["VoiceKit"])],
    targets: [.target(name: "VKObjC"),
              .target(name: "VoiceKit", dependencies: ["VKObjC"])],
    swiftLanguageModes: [.v5])
