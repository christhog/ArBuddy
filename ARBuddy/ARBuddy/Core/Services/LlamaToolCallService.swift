//
//  LlamaToolCallService.swift
//  ARBuddy
//
//  Created by Claude on 12.04.26.
//

import Foundation
import Combine
import CoreLocation

// MARK: - Tool Call Service

/// Service for parsing and executing tool calls from LLM output
final class LlamaToolCallService: @unchecked Sendable {
    static let shared = LlamaToolCallService()

    private var chatHistoryStore: ChatHistoryStore?
    private var locationProvider: (@Sendable () async -> CLLocation?)?

    private init() {}

    /// Sets the chat history store for accessing recent messages
    func setChatHistoryStore(_ store: ChatHistoryStore) {
        self.chatHistoryStore = store
    }

    /// Sets a closure that provides the current location
    func setLocationProvider(_ provider: @escaping @Sendable () async -> CLLocation?) {
        self.locationProvider = provider
    }

    // MARK: - Tool Execution

    /// Executes a tool call and returns the result
    func execute(_ toolCall: ToolCall) async -> ToolCallResult {
        print("[ToolCall] Executing: \(toolCall.name)")

        guard let tool = BuddyTool(rawValue: toolCall.name) else {
            return ToolCallResult(
                toolName: toolCall.name,
                parameters: toolCall.parameters,
                resultText: "Unbekanntes Tool: \(toolCall.name)",
                success: false
            )
        }

        do {
            let result: String

            switch tool {
            case .getUserInfo:
                result = try await executeGetUserInfo()

            case .getNearbyPlaces:
                let radiusStr = toolCall.parameters["radius"] ?? "500"
                let radius = Double(radiusStr) ?? 500
                result = try await executeGetNearbyPlaces(radius: radius)

            case .getRecentTalks:
                let limitStr = toolCall.parameters["limit"] ?? "5"
                let limit = Int(limitStr) ?? 5
                result = await executeGetRecentTalks(limit: limit)

            case .queryCloudAI:
                let query = toolCall.parameters["query"] ?? ""
                result = try await executeQueryCloudAI(query: query)
            }

            return ToolCallResult(
                toolName: toolCall.name,
                parameters: toolCall.parameters,
                resultText: result,
                success: true
            )

        } catch {
            return ToolCallResult(
                toolName: toolCall.name,
                parameters: toolCall.parameters,
                resultText: "Fehler: \(error.localizedDescription)",
                success: false
            )
        }
    }

    // MARK: - Tool Implementations

    /// Gets user information (level, XP, visited places)
    private func executeGetUserInfo() async throws -> String {
        let (user, stats) = await MainActor.run {
            (SupabaseService.shared.currentUser, SupabaseService.shared.userStatistics)
        }

        guard let user = user else {
            return "Benutzer nicht eingeloggt."
        }

        var info: [String] = []
        info.append("Level: \(user.level)")
        info.append("XP: \(user.xp)")
        info.append("XP bis nächstes Level: \(user.xpToNextLevel)")
        info.append("Besuchte Orte: \(stats.totalPoisVisited)")
        info.append("Abgeschlossene POIs: \(stats.fullyCompletedPois)")

        return info.joined(separator: "\n")
    }

    /// Gets nearby places
    private func executeGetNearbyPlaces(radius: Double) async throws -> String {
        // Get current location from the provider
        guard let locationProvider = locationProvider,
              let location = await locationProvider() else {
            return "Standort nicht verfügbar. Bitte aktiviere die Ortungsdienste."
        }

        // Fetch POIs from database
        let pois = try await POIService.shared.fetchPOIsFromDatabase(
            near: location.coordinate,
            radius: radius
        )

        if pois.isEmpty {
            return "Keine interessanten Orte im Umkreis von \(Int(radius))m gefunden."
        }

        // Format results
        var result = "Orte im Umkreis von \(Int(radius))m:\n"
        for (index, poi) in pois.prefix(5).enumerated() {
            let distance = location.distance(from: CLLocation(latitude: poi.latitude, longitude: poi.longitude))
            result += "\(index + 1). \(poi.name) (\(poi.category)) - \(Int(distance))m entfernt\n"
        }

        if pois.count > 5 {
            result += "... und \(pois.count - 5) weitere Orte"
        }

        return result
    }

    /// Gets recent chat messages
    private func executeGetRecentTalks(limit: Int) async -> String {
        guard let store = chatHistoryStore else {
            return "Chat-Verlauf nicht verfügbar."
        }

        let messages = await store.getRecentMessages(limit: limit)

        if messages.isEmpty {
            return "Keine vorherigen Nachrichten gefunden."
        }

        var result = "Letzte Nachrichten:\n"
        for message in messages {
            let rolePrefix = message.role == .user ? "Du" : "Ich"
            let preview = String(message.content.prefix(50))
            result += "- \(rolePrefix): \(preview)\(message.content.count > 50 ? "..." : "")\n"
        }

        return result
    }

    /// Queries cloud AI for complex questions
    private func executeQueryCloudAI(query: String) async throws -> String {
        guard !query.isEmpty else {
            return "Keine Frage angegeben."
        }

        // TODO: Implement cloud AI query via Supabase Edge Function
        // For now, return a placeholder response
        return "Cloud-KI Anfrage: \"\(query)\"\n[Cloud-KI Integration noch nicht implementiert]"
    }

    // MARK: - Response Processing

    /// Processes LLM output, executing any tool calls and building the final response
    func processResponse(_ response: String) async -> ProcessedResponse {
        var textParts: [String] = []
        var toolResults: [ToolCallResult] = []
        var remaining = response

        // Extract and execute tool calls
        while ToolCall.containsToolCall(remaining) {
            let (before, after) = ToolCall.extractTextParts(from: remaining)

            if !before.isEmpty {
                textParts.append(before)
            }

            if let toolCall = ToolCall.parse(from: remaining) {
                let result = await execute(toolCall)
                toolResults.append(result)
            }

            remaining = after
        }

        // Add any remaining text
        if !remaining.isEmpty {
            textParts.append(remaining)
        }

        return ProcessedResponse(
            displayText: textParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            toolResults: toolResults
        )
    }
}

// MARK: - Processed Response

/// Result of processing an LLM response
struct ProcessedResponse: Sendable {
    let displayText: String
    let toolResults: [ToolCallResult]

    var hasToolCalls: Bool {
        !toolResults.isEmpty
    }

    /// Combines display text with tool results for context
    var contextText: String {
        var parts = [displayText]
        for result in toolResults {
            parts.append("[Tool \(result.toolName): \(result.resultText)]")
        }
        return parts.joined(separator: "\n")
    }
}
