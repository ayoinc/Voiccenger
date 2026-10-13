// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Voiccenger",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Voiccenger", targets: ["Voiccenger"]),
        .executable(name: "voiccenger-cli", targets: ["voiccenger-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.17.7")),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.10.0"),
    ],
    targets: [
        // Shared value types and protocols. No framework dependencies beyond Foundation.
        .target(name: "VCModels"),
        // Microphone / system-audio capture, recording, meeting + conversation detection.
        .target(name: "VCAudio", dependencies: ["VCModels"]),
        // Live transcription (SpeechAnalyzer), language + accent detection.
        .target(name: "VCTranscription", dependencies: ["VCModels"]),
        // Diarization + enrolled-voice identification (FluidAudio).
        .target(
            name: "VCSpeakers",
            dependencies: ["VCModels", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        // GCC-PHAT direction of arrival, seat tracking, array simulation.
        .target(name: "VCSpatial", dependencies: ["VCModels"]),
        // Intent, speech correction, summaries (Foundation Models + Claude).
        .target(name: "VCIntelligence", dependencies: ["VCModels"]),
        // Orchestration: session, alignment, storage, report rendering.
        .target(
            name: "VCPipeline",
            dependencies: ["VCModels", "VCAudio", "VCTranscription", "VCSpeakers", "VCSpatial", "VCIntelligence"]
        ),
        .executableTarget(
            name: "Voiccenger",
            dependencies: ["VCPipeline", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .executableTarget(name: "voiccenger-cli", dependencies: ["VCPipeline"]),

        .testTarget(name: "VCModelsTests", dependencies: ["VCModels"]),
        .testTarget(name: "VCAudioTests", dependencies: ["VCAudio"]),
        .testTarget(name: "VCTranscriptionTests", dependencies: ["VCTranscription"]),
        .testTarget(name: "VCSpeakersTests", dependencies: ["VCSpeakers"]),
        .testTarget(name: "VCSpatialTests", dependencies: ["VCSpatial"]),
        .testTarget(name: "VCIntelligenceTests", dependencies: ["VCIntelligence"]),
        .testTarget(name: "VCPipelineTests", dependencies: ["VCPipeline"]),
    ],
    swiftLanguageModes: [.v6]
)
