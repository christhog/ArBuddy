//
//  LlamaModel.swift
//  ARBuddy
//
//  Created by Claude on 12.04.26.
//

import Foundation
import Combine

// MARK: - Device Tier

/// Device tier based on available memory - determines model and parameters
enum DeviceTier: String, CaseIterable, Codable {
    case lowMemory   // iPhone 11 and older (4GB RAM) - 1B model, minimal context
    case standard    // iPhone 12/13/14 (6GB RAM) - 1B model, normal context
    case pro         // iPhone 14 Pro/15 (6-8GB RAM) - 3B model possible
    case max         // iPhone 15 Pro Max+ (8GB+ RAM) - 3B model, full context

    /// Device memory in GB
    static var deviceMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    /// Detect device tier based on physical memory
    static func detect() -> DeviceTier {
        let memoryGB = deviceMemoryGB

        if memoryGB >= 8.0 {
            return .max
        } else if memoryGB >= 6.0 {
            // Check if it's a Pro device (can handle 3B with care)
            // 6GB devices should use 1B model but with full context
            return .pro
        } else if memoryGB >= 5.0 {
            return .standard
        }
        return .lowMemory
    }

    var displayName: String {
        switch self {
        case .lowMemory:
            return "Basis"
        case .standard:
            return "Standard"
        case .pro:
            return "Pro"
        case .max:
            return "Max"
        }
    }

    var description: String {
        switch self {
        case .lowMemory:
            return "Für ältere Geräte (4GB RAM)"
        case .standard:
            return "Für Geräte mit 5-6GB RAM"
        case .pro:
            return "Für Pro-Geräte (6-8GB RAM)"
        case .max:
            return "Für Geräte mit 8GB+ RAM"
        }
    }

    /// Recommended context length for this tier
    var recommendedContextLength: Int {
        switch self {
        case .lowMemory:
            return 512
        case .standard:
            return 1024
        case .pro:
            return 2048
        case .max:
            return 4096
        }
    }

    /// Maximum output tokens for this tier
    var recommendedMaxTokens: Int {
        switch self {
        case .lowMemory:
            return 256
        case .standard:
            return 384
        case .pro:
            return 512
        case .max:
            return 1024
        }
    }

    /// Whether this tier can run the 3B model
    var canRun3BModel: Bool {
        switch self {
        case .lowMemory, .standard:
            return false
        case .pro:
            return true  // Possible but tight
        case .max:
            return true
        }
    }

    /// Recommended model ID for this tier
    var recommendedModelId: String {
        switch self {
        case .lowMemory:
            return "qwen2.5-0.5b-q2k"  // Multilingual model for 4GB devices
        case .standard, .pro:
            return "llama-3.2-1b-q4km"
        case .max:
            return "llama-3.2-3b-q4km"
        }
    }

    /// Get recommended parameters for this tier
    var recommendedParameters: LlamaModelParameters {
        LlamaModelParameters(
            temperature: 0.7,
            topP: 0.9,
            topK: 40,
            maxTokens: recommendedMaxTokens,
            repeatPenalty: 1.1,
            contextLength: recommendedContextLength
        )
    }
}

// MARK: - Llama Model Info

/// Information about an available Llama model
struct LlamaModelInfo: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let displayName: String
    let description: String
    let sizeBytes: Int64
    let downloadURL: URL
    let tier: DeviceTier
    let contextLength: Int
    let quantization: String

    enum CodingKeys: String, CodingKey {
        case id, name, displayName, description, sizeBytes, downloadURL, tier, contextLength, quantization
    }

    init(id: String, name: String, displayName: String, description: String, sizeBytes: Int64, downloadURL: URL, tier: DeviceTier, contextLength: Int, quantization: String) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.description = description
        self.sizeBytes = sizeBytes
        self.downloadURL = downloadURL
        self.tier = tier
        self.contextLength = contextLength
        self.quantization = quantization
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        displayName = try container.decode(String.self, forKey: .displayName)
        description = try container.decode(String.self, forKey: .description)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        downloadURL = try container.decode(URL.self, forKey: .downloadURL)
        let tierRaw = try container.decode(String.self, forKey: .tier)
        tier = DeviceTier(rawValue: tierRaw) ?? .standard
        contextLength = try container.decode(Int.self, forKey: .contextLength)
        quantization = try container.decode(String.self, forKey: .quantization)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(description, forKey: .description)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encode(downloadURL, forKey: .downloadURL)
        try container.encode(tier.rawValue, forKey: .tier)
        try container.encode(contextLength, forKey: .contextLength)
        try container.encode(quantization, forKey: .quantization)
    }

    /// Formatted file size string
    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: sizeBytes)
    }

    /// Local filename for caching
    var localFileName: String {
        "\(id).gguf"
    }
}

// MARK: - Available Models

extension LlamaModelInfo {
    /// Available models for download
    static let availableModels: [LlamaModelInfo] = [
        // Multilingual Model: For lowMemory tier (4GB RAM devices like iPhone 11)
        // Qwen2.5 0.5B - ~415MB, trained on 29+ languages including German
        LlamaModelInfo(
            id: "qwen2.5-0.5b-q2k",
            name: "qwen2.5-0.5b-instruct-q2_k.gguf",
            displayName: "Qwen2.5 0.5B",
            description: "Kompaktes multilinguales Modell (Deutsch)",
            sizeBytes: 415_000_000,  // ~415MB
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q2_k.gguf")!,
            tier: .lowMemory,
            contextLength: 2048,
            quantization: "Q2_K"
        ),
        // 1B Model: For standard and pro tiers
        LlamaModelInfo(
            id: "llama-3.2-1b-q4km",
            name: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            displayName: "Llama 3.2 1B",
            description: "Kompaktes Modell für schnelle Antworten",
            sizeBytes: 700_000_000,  // ~700MB
            downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")!,
            tier: .standard,
            contextLength: 8192,
            quantization: "Q4_K_M"
        ),
        // 3B Model: For max tier (8GB+ RAM)
        LlamaModelInfo(
            id: "llama-3.2-3b-q4km",
            name: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            displayName: "Llama 3.2 3B",
            description: "Größeres Modell für bessere Qualität",
            sizeBytes: 2_000_000_000,  // ~2GB
            downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
            tier: .max,
            contextLength: 8192,
            quantization: "Q4_K_M"
        )
    ]

    /// Get recommended model for current device based on detected tier
    static func recommendedModel() -> LlamaModelInfo {
        let tier = DeviceTier.detect()
        let recommendedId = tier.recommendedModelId
        return availableModels.first { $0.id == recommendedId } ?? availableModels[0]
    }

    /// Get model by ID
    static func model(withId id: String) -> LlamaModelInfo? {
        availableModels.first { $0.id == id }
    }

    /// Check if device can run this model
    func canRunOnCurrentDevice() -> Bool {
        let tier = DeviceTier.detect()
        switch id {
        case "llama-3.2-3b-q4km":
            return tier.canRun3BModel
        case "llama-3.2-1b-q4km":
            return tier != .lowMemory
        default:
            return true
        }
    }
}

// MARK: - Llama Model Parameters

/// Parameters for model inference
struct LlamaModelParameters: Codable, Equatable {
    var temperature: Float = 0.7
    var topP: Float = 0.9
    var topK: Int = 40
    var maxTokens: Int = 512
    var repeatPenalty: Float = 1.1
    var contextLength: Int = 2048  // Context window size - affects RAM usage significantly
    var seed: Int = -1  // -1 for random

    static let `default` = LlamaModelParameters()

    /// Conservative parameters for quick responses
    static let quick = LlamaModelParameters(
        temperature: 0.5,
        topP: 0.85,
        topK: 30,
        maxTokens: 256,
        repeatPenalty: 1.1
    )

    /// Creative parameters for more varied responses
    static let creative = LlamaModelParameters(
        temperature: 0.9,
        topP: 0.95,
        topK: 50,
        maxTokens: 512,
        repeatPenalty: 1.05
    )

    /// Recommended parameters based on device tier (auto-detected)
    static var recommended: LlamaModelParameters {
        DeviceTier.detect().recommendedParameters
    }
}

// MARK: - Model State

/// Current state of the LLM model
enum LlamaModelState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case loading
    case loaded
    case unloading
    case error(String)

    var isReady: Bool {
        self == .loaded
    }

    var displayText: String {
        switch self {
        case .notDownloaded:
            return "Nicht heruntergeladen"
        case .downloading(let progress):
            return "Lädt... \(Int(progress * 100))%"
        case .downloaded:
            return "Heruntergeladen"
        case .loading:
            return "Wird geladen..."
        case .loaded:
            return "Bereit"
        case .unloading:
            return "Wird entladen..."
        case .error(let message):
            return "Fehler: \(message)"
        }
    }
}
