// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Sideport",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CMTP", pkgConfig: "libmtp", providers: [.brew(["libmtp"])]),
        .executableTarget(name: "Sideport", dependencies: ["CMTP"]),
    ]
)
