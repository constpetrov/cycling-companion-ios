// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RoutePersistence",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "RoutePersistence", targets: ["RoutePersistence"])
    ],
    targets: [
        .target(name: "RoutePersistence")
    ]
)
