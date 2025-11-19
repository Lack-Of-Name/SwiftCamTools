// swift-tools-version: 5.9
import PackageDescription

let applePlatformSupport: Bool = {
    #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
    return true
    #else
    return false
    #endif
}()

let metalPetalDependency: [Package.Dependency] = applePlatformSupport ? [
    .package(url: "https://github.com/MetalPetal/MetalPetal.git", branch: "master")
] : []

let imagingDependencies: [Target.Dependency] = applePlatformSupport ? [
    "SwiftCamCore",
    "MetalPetal"
] : [
    "SwiftCamCore"
]

let package = Package(
    name: "SwiftCamToolsKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "SwiftCamCore", targets: ["SwiftCamCore"]),
        .library(name: "SwiftCamImaging", targets: ["SwiftCamImaging"]),
        .library(name: "SwiftCamCamera", targets: ["SwiftCamCamera"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-algorithms.git", from: "1.2.0")
    ] + metalPetalDependency,
    targets: [
        .target(
            name: "SwiftCamCore",
            dependencies: [
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Algorithms", package: "swift-algorithms")
            ],
            path: "Sources/SwiftCamCore"
        ),
        .target(
            name: "SwiftCamImaging",
            dependencies: imagingDependencies,
            path: "Sources/SwiftCamImaging",
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "SwiftCamCamera",
            dependencies: [
                "SwiftCamCore",
                "SwiftCamImaging"
            ],
            path: "Sources/SwiftCamCamera"
        ),
        .testTarget(
            name: "SwiftCamToolsKitTests",
            dependencies: ["SwiftCamCore", "SwiftCamImaging", "SwiftCamCamera"],
            path: "Tests/SwiftCamToolsKitTests"
        )
    ]
)
