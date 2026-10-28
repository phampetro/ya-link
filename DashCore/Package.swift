// swift-tools-version:5.9
// DashCore: phần lõi không phụ thuộc giao diện (khung lệnh Link A, CRC, bắt tay với đồng hồ).
// Chỉ dùng Foundation để sau này dịch sang Android (Kotlin) theo đúng các test vectors.
import PackageDescription

let package = Package(
    name: "DashCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "DashCore", targets: ["DashCore"]),
    ],
    targets: [
        .target(name: "DashCore", path: "Sources/DashCore"),
        .testTarget(
            name: "DashCoreTests",
            dependencies: ["DashCore"],
            path: "Tests/DashCoreTests",
            resources: [.copy("vectors")]
        ),
    ]
)
