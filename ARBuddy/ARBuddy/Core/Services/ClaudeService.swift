//
//  ClaudeService.swift
//  ARBuddy
//
//  Created by Claude on 14.04.26.
//

import Foundation

/// Service for Claude AI chat completion via Supabase Edge Function
actor ClaudeService {
    static let shared = ClaudeService()

    // MARK: - Configuration

    private let supabaseURL: String
    private let supabaseAnonKey: String

    // MARK: - Initialization

    private init() {
        // Get Supabase configuration (same as SupabaseService)
        self.supabaseURL = "https://ibhaixdirrejsxalntvx.supabase.co"
        self.supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImliaGFpeGRpcnJlanN4YWxudHZ4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg1NjU0NjksImV4cCI6MjA4NDE0MTQ2OX0.966UbEaN19b3leFVi0PR_H1j0F95yAOW8C-oEGHbbyw"
    }

    // MARK: - Public API

    /// Generates a response using Claude Haiku via Supabase Edge Function
    /// - Parameters:
    ///   - prompt: The user's message
    ///   - systemPrompt: System prompt for context
    ///   - conversationHistory: Recent conversation history for context
    /// - Returns: AsyncThrowingStream of response tokens
    func generate(
        prompt: String,
        systemPrompt: String,
        conversationHistory: [ChatMessage] = []
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.streamResponse(
                        prompt: prompt,
                        systemPrompt: systemPrompt,
                        conversationHistory: conversationHistory,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private Implementation

    private func streamResponse(
        prompt: String,
        systemPrompt: String,
        conversationHistory: [ChatMessage],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        // Build messages array for Claude API
        var messages: [[String: String]] = []

        // Add conversation history (limit to last 10 messages)
        for message in conversationHistory.suffix(10) {
            let role = message.isUser ? "user" : "assistant"
            messages.append(["role": role, "content": message.content])
        }

        // Add the current prompt
        messages.append(["role": "user", "content": prompt])

        // Build request body
        let requestBody: [String: Any] = [
            "messages": messages,
            "systemPrompt": systemPrompt,
            "maxTokens": 1024
        ]

        // Create request
        guard let url = URL(string: "\(supabaseURL)/functions/v1/chat-completion") else {
            throw ClaudeServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        print("[ClaudeService] Sending request with \(messages.count) messages")

        // Perform streaming request
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeServiceError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw ClaudeServiceError.httpError(statusCode: httpResponse.statusCode)
        }

        // Parse SSE stream using bytes.lines which handles UTF-8 correctly
        // (byte-by-byte reading breaks multi-byte characters like ü, ä, ß)
        for try await line in bytes.lines {
            if let text = parseSSELine(line) {
                continuation.yield(text)
            }
        }

        continuation.finish()
        print("[ClaudeService] Stream completed")
    }

    /// Parses an SSE line and extracts the text content
    private func parseSSELine(_ line: String) -> String? {
        // SSE format: "data: {json}"
        guard line.hasPrefix("data: ") else { return nil }

        let jsonString = String(line.dropFirst(6))

        // Skip keep-alive messages and end markers
        if jsonString.isEmpty || jsonString == "[DONE]" { return nil }

        // Parse Anthropic streaming format
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Anthropic streaming format: different event types
        guard let eventType = json["type"] as? String else { return nil }

        switch eventType {
        case "content_block_delta":
            // Extract text delta
            if let delta = json["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                return text
            }
        case "message_start", "content_block_start", "message_delta", "message_stop":
            // These are control events, no text to yield
            return nil
        default:
            return nil
        }

        return nil
    }
}

// MARK: - Errors

enum ClaudeServiceError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case parsingError

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Ungültige URL"
        case .invalidResponse:
            return "Ungültige Server-Antwort"
        case .httpError(let statusCode):
            return "Server-Fehler: \(statusCode)"
        case .parsingError:
            return "Fehler beim Verarbeiten der Antwort"
        }
    }
}
