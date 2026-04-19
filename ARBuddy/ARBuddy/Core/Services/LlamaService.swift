//
//  LlamaService.swift
//  ARBuddy
//
//  Created by Claude on 12.04.26.
//

import Foundation
import Combine
import LLM

// MARK: - Chat Templates

extension Template {
    /// Template for Llama 3 models
    static func llama3(_ systemPrompt: String? = nil) -> Template {
        return Template(
            prefix: "<|begin_of_text|>",
            system: ("<|start_header_id|>system<|end_header_id|>\n\n", "<|eot_id|>"),
            user: ("<|start_header_id|>user<|end_header_id|>\n\n", "<|eot_id|>"),
            bot: ("<|start_header_id|>assistant<|end_header_id|>\n\n", "<|eot_id|>"),
            stopSequence: "<|eot_id|>",
            systemPrompt: systemPrompt
        )
    }

    /// Template for SmolLM2 models (uses ChatML format)
    static func smolLM(_ systemPrompt: String? = nil) -> Template {
        return .chatML(systemPrompt)
    }

    /// Get appropriate template for a model
    static func forModel(_ modelId: String, systemPrompt: String? = nil) -> Template {
        if modelId.contains("smollm") || modelId.contains("qwen") {
            return .chatML(systemPrompt)  // SmolLM and Qwen use ChatML format
        } else {
            return .llama3(systemPrompt)
        }
    }
}

// MARK: - Llama Service Errors

enum LlamaServiceError: LocalizedError {
    case modelNotLoaded
    case modelAlreadyLoaded
    case loadFailed(String)
    case generationFailed(String)
    case invalidModelFile
    case contextCreationFailed

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Kein Modell geladen"
        case .modelAlreadyLoaded:
            return "Ein Modell ist bereits geladen"
        case .loadFailed(let reason):
            return "Modell konnte nicht geladen werden: \(reason)"
        case .generationFailed(let reason):
            return "Textgenerierung fehlgeschlagen: \(reason)"
        case .invalidModelFile:
            return "Ungültige Modelldatei"
        case .contextCreationFailed:
            return "Kontext konnte nicht erstellt werden"
        }
    }
}

// MARK: - Llama Service

/// Actor for managing LLM inference with LLM.swift
actor LlamaService {
    static let shared = LlamaService()

    // MARK: - State

    private(set) var currentModel: LlamaModelInfo?
    private(set) var isLoaded = false
    private(set) var isGenerating = false

    /// The LLM instance from LLM.swift
    private var llm: LLM?

    /// System prompt for the current session
    private var currentSystemPrompt: String = ""

    private let downloadService = LlamaModelDownloadService.shared

    private init() {}

    // MARK: - Model State

    /// Current state of the model (synchronous check)
    var modelState: LlamaModelState {
        if isLoaded {
            return .loaded
        }
        return .notDownloaded
    }

    /// Async version that checks cache status
    func getModelState() async -> LlamaModelState {
        if isLoaded {
            return .loaded
        }
        if let model = currentModel {
            let isCached = await downloadService.isModelCached(for: model)
            if isCached {
                return .downloaded
            }
        }
        return .notDownloaded
    }

    // MARK: - Model Management

    /// Loads a model from a local URL (internal use - prefer loadModel(_ model:) for proper template selection)
    private func loadModelFromURL(_ url: URL, modelId: String, parameters: LlamaModelParameters) async throws {
        guard !isLoaded else {
            throw LlamaServiceError.modelAlreadyLoaded
        }

        print("[LlamaService] Loading model from: \(url.path)")
        print("[LlamaService] Model ID: \(modelId)")

        // Verify file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LlamaServiceError.invalidModelFile
        }

        // Select the appropriate template based on model type
        let template = Template.forModel(modelId, systemPrompt: nil)
        print("[LlamaService] Using template for: \(modelId.contains("smollm") || modelId.contains("qwen") ? "ChatML" : "Llama 3")")

        // Initialize LLM with the model file path
        // Use contextLength for the context window size (affects RAM usage significantly)
        guard let loadedLLM = LLM(
            from: url,
            template: template,
            topK: Int32(parameters.topK),
            topP: parameters.topP,
            temp: parameters.temperature,
            repeatPenalty: parameters.repeatPenalty,
            maxTokenCount: Int32(parameters.contextLength)
        ) else {
            throw LlamaServiceError.loadFailed("Failed to initialize LLM")
        }

        print("[LlamaService] Loaded with context length: \(parameters.contextLength)")

        llm = loadedLLM
        isLoaded = true
        print("[LlamaService] Model loaded successfully")
    }

    /// Loads a model by its info
    func loadModel(_ model: LlamaModelInfo, parameters: LlamaModelParameters = .default) async throws {
        let url = await downloadService.localModelURL(for: model)

        guard await downloadService.isModelCached(for: model) else {
            throw LlamaServiceError.loadFailed("Model not downloaded")
        }

        currentModel = model
        try await loadModelFromURL(url, modelId: model.id, parameters: parameters)
    }

    /// Loads a model from a URL with a specified model ID (for custom models)
    func loadModel(from url: URL, modelId: String = "llama-3.2-1b-q4km", parameters: LlamaModelParameters = .default) async throws {
        try await loadModelFromURL(url, modelId: modelId, parameters: parameters)
    }

    /// Unloads the current model to free memory
    func unloadModel() {
        guard isLoaded else { return }

        print("[LlamaService] Unloading model")

        llm = nil
        isLoaded = false
        currentModel = nil

        print("[LlamaService] Model unloaded")
    }

    // MARK: - Text Generation

    /// Generates text with streaming output
    func generate(
        prompt: String,
        systemPrompt: String = "",
        parameters: LlamaModelParameters = .default
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let llm = llm else {
                        continuation.finish(throwing: LlamaServiceError.modelNotLoaded)
                        return
                    }

                    guard isLoaded else {
                        continuation.finish(throwing: LlamaServiceError.modelNotLoaded)
                        return
                    }

                    isGenerating = true
                    defer { isGenerating = false }

                    print("[LlamaService] Generating with prompt length: \(prompt.count)")

                    // Update template with system prompt if different
                    if systemPrompt != currentSystemPrompt {
                        let modelId = currentModel?.id ?? "llama-3.2-1b-q4km"
                        llm.template = Template.forModel(modelId, systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt)
                        currentSystemPrompt = systemPrompt
                    }

                    // Set up callback to yield tokens as they're generated
                    var accumulatedOutput = ""

                    llm.update = { delta in
                        if let delta = delta {
                            continuation.yield(delta)
                            accumulatedOutput += delta
                        }
                    }

                    // Generate response using LLM.swift's respond method
                    await llm.respond(to: prompt)

                    // If no tokens were yielded through callback, yield the final output
                    if accumulatedOutput.isEmpty {
                        let output = llm.output
                        if !output.isEmpty {
                            continuation.yield(output)
                        }
                    }

                    continuation.finish()

                } catch {
                    print("[LlamaService] Generation error: \(error)")
                    continuation.finish(throwing: LlamaServiceError.generationFailed(error.localizedDescription))
                }
            }
        }
    }

    /// Generates a complete response (non-streaming)
    func generateComplete(
        prompt: String,
        systemPrompt: String = "",
        parameters: LlamaModelParameters = .default
    ) async throws -> String {
        guard let llm = llm else {
            throw LlamaServiceError.modelNotLoaded
        }

        guard isLoaded else {
            throw LlamaServiceError.modelNotLoaded
        }

        isGenerating = true
        defer { isGenerating = false }

        // Update template with system prompt if different
        if systemPrompt != currentSystemPrompt {
            let modelId = currentModel?.id ?? "llama-3.2-1b-q4km"
            llm.template = Template.forModel(modelId, systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt)
            currentSystemPrompt = systemPrompt
        }

        // Reset history for fresh generation
        llm.reset()

        // Generate response
        await llm.respond(to: prompt)

        return llm.output
    }

    // MARK: - Memory Management

    /// Called when system memory is low
    func handleMemoryWarning() {
        print("[LlamaService] Memory warning received")
        if isLoaded && !isGenerating {
            unloadModel()
        }
    }

    /// Estimates memory usage for a model
    func estimateMemoryUsage(for model: LlamaModelInfo) -> Int64 {
        // Rough estimate: model size + context buffer
        // Q4 quantized models use about 1.5x their file size in RAM
        return Int64(Double(model.sizeBytes) * 1.5) + 256_000_000 // + 256MB for context
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let llamaModelLoaded = Notification.Name("llamaModelLoaded")
    static let llamaModelUnloaded = Notification.Name("llamaModelUnloaded")
}
