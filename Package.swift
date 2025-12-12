// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipFlowApp",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "ClipFlowApp", targets: ["ClipFlowApp"])
    ],
    targets: [
        .executableTarget(
            name: "ClipFlowApp",
            path: ".",
            sources: ["ClipFlowApp.swift"]
        )
    ]
)
