// swift-tools-version:5.9
// DashCore: phần lõi không phụ thuộc giao diện (khung lệnh Link A, CRC, bắt tay với đồng hồ).
// Chỉ dùng Foundation để sau này dịch sang Android (Kotlin) theo đúng các test vectors.
import PackageDescription

let package = Package(
    name: "DashCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "DashCore", targets: ["DashCore"]),
        .library(name: "DashRender", targets: ["DashRender"]),
    ],
    targets: [
        .target(name: "DashCore", path: "Sources/DashCore"),
        // Bộ vẽ khung hình (CoreGraphics + CoreText, vẽ bằng CPU nên chạy được khi khoá máy)
        .target(name: "DashRender", dependencies: ["DashCore"], path: "Sources/DashRender"),
        .testTarget(name: "DashRenderTests", dependencies: ["DashRender"], path: "Tests/DashRenderTests"),
        .testTarget(
            name: "DashCoreTests",
            dependencies: ["DashCore"],
            path: "Tests/DashCoreTests",
            resources: [.copy("vectors")]
        ),
    ]
)
