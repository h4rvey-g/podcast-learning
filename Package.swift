// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PodcastLearning",
    platforms: [.iOS("18.0"), .macOS(.v14)],
    products: [.library(name: "PodcastCore", targets: ["PodcastCore"])],
    targets: [
        .target(name: "PodcastCore", resources: [.copy("Resources/wordlist.json")]),
        .testTarget(name: "PodcastCoreTests", dependencies: ["PodcastCore"], resources: [.copy("Fixtures")])
    ]
)
