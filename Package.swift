// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PodcastLearning",
    platforms: [.iOS("18.0"), .macOS(.v14)],
    products: [.library(name: "PodcastCore", targets: ["PodcastCore"]), .library(name: "PodcastAI", targets: ["PodcastAI"])],
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", exact: "5.10.2"),
        .package(url: "https://github.com/teunlao/swift-ai-sdk.git", revision: "4e0230a06092583c4dd541071b1ce8e181821bf9")
    ],
    targets: [
        .target(name: "PodcastCore", dependencies: ["Alamofire"], resources: [.copy("Resources/wordlist.json")]),
        .target(name: "PodcastAI", dependencies: ["PodcastCore", .product(name: "SwiftAISDK", package: "swift-ai-sdk"), .product(name: "OpenAIProvider", package: "swift-ai-sdk"), .product(name: "AnthropicProvider", package: "swift-ai-sdk"), .product(name: "GoogleProvider", package: "swift-ai-sdk")]),
        .testTarget(name: "PodcastAITests", dependencies: ["PodcastAI", .product(name: "AISDKProviderUtils", package: "swift-ai-sdk")]),
        .testTarget(name: "PodcastCoreTests", dependencies: ["PodcastCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "LiveProviderTests", dependencies: [
            "PodcastCore", "PodcastAI",
            .product(name: "Alamofire", package: "Alamofire")
        ])
    ]
)
