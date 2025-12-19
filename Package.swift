// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "swift-resource-pool",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(
            name: "ResourcePool",
            targets: ["ResourcePool"]
        ),
    ],
    targets: [
        .target(
            name: "ResourcePool"
        ),
        .testTarget(
            name: "ResourcePoolTests",
            dependencies: ["ResourcePool"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("StrictUnsafe"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
//    .unsafeFlags(["-warnings-as-errors"]),
]

for index in package.targets.indices {
    package.targets[index].swiftSettings = (package.targets[index].swiftSettings ?? []) + swiftSettings
}
