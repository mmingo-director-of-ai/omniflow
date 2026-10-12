// swift-tools-version: 6.2
import PackageDescription
// Test the production source without launching a second desktop application.
// Core (including the native Atlas runtime in Core/AtlasRuntime) compiles into
// the same module as App, as it does in Xcode.
let package = Package(name: "OmniFlowChecks", platforms: [.macOS("27.0"), .iOS("27.0")], dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "e560c6445ffdc42e60c7b282d162aae271f18e2a"),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "7a9b7e66fe839d248a2fc00e244dd04ea1aa384d"),
    .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.32.3"),
    .package(url: "https://github.com/huggingface/swift-transformers.git", revision: "af520cfccbbdc2127a0b77a1547fa47b7cd1f8d8")
], targets: [
    .target(name: "OmniFlowApp", dependencies: [
        .product(name: "FluidAudio", package: "FluidAudio"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "Tokenizers", package: "swift-transformers")
    ], path: "OmniFlow", exclude: ["Sources/App/OmniFlowMain.swift", "Sources/Core/AtlasRuntime/AtlasRuntime-LICENSE.txt"],
            sources: ["Sources/App", "Sources/Core", "Shared"]),
    .testTarget(name: "OmniFlowFreeFlowTests", dependencies: ["OmniFlowApp"], path: "tests/FreeFlow"),
    .testTarget(name: "AtlasRuntimeTests", dependencies: ["OmniFlowApp"], path: "tests/AtlasRuntime", exclude: ["Fixtures"])
], swiftLanguageModes: [.v6])
