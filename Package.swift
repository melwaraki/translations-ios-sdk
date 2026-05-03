// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Translations",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "Translations",
            targets: ["Translations"]
        )
    ],
    targets: [
        .target(
            name: "Translations",
            path: "Sources/Translations"
        ),
        .testTarget(
            name: "TranslationsTests",
            dependencies: ["Translations"],
            path: "Tests/TranslationsTests"
        )
    ]
)
