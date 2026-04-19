//
//  ChatMessage.swift
//  ARBuddy
//
//  Created by Claude on 12.04.26.
//

import Foundation
import Combine

// MARK: - Message Role

enum ChatMessageRole: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
    case system
    case tool

    var displayName: String {
        switch self {
        case .user:
            return "Du"
        case .assistant:
            return "Buddy"
        case .system:
            return "System"
        case .tool:
            return "Tool"
        }
    }
}

// MARK: - Chat Message

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let role: ChatMessageRole
    var content: String
    let timestamp: Date
    var isStreaming: Bool
    var toolCalls: [ToolCallResult]?

    init(
        id: UUID = UUID(),
        role: ChatMessageRole,
        content: String,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        toolCalls: [ToolCallResult]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.toolCalls = toolCalls
    }

    /// Creates a user message
    static func user(_ content: String) -> ChatMessage {
        ChatMessage(role: .user, content: content)
    }

    /// Creates an assistant message
    static func assistant(_ content: String, isStreaming: Bool = false) -> ChatMessage {
        ChatMessage(role: .assistant, content: content, isStreaming: isStreaming)
    }

    /// Creates a system message
    static func system(_ content: String) -> ChatMessage {
        ChatMessage(role: .system, content: content)
    }

    /// Creates a tool result message
    static func toolResult(_ result: ToolCallResult) -> ChatMessage {
        ChatMessage(role: .tool, content: result.resultText, toolCalls: [result])
    }

    /// Formatted timestamp for display
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    /// Whether this message is from the user
    var isUser: Bool {
        role == .user
    }

    /// Whether this message is from the assistant
    var isAssistant: Bool {
        role == .assistant
    }

    // MARK: - Equatable

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id &&
        lhs.role == rhs.role &&
        lhs.content == rhs.content &&
        lhs.isStreaming == rhs.isStreaming
    }
}

// MARK: - Chat Conversation

struct ChatConversation: Identifiable, Codable, Sendable {
    let id: UUID
    var messages: [ChatMessage]
    let createdAt: Date
    var updatedAt: Date
    var title: String?

    init(
        id: UUID = UUID(),
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        title: String? = nil
    ) {
        self.id = id
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.title = title
    }

    /// Adds a message to the conversation
    mutating func addMessage(_ message: ChatMessage) {
        messages.append(message)
        updatedAt = Date()
    }

    /// Updates the last message (for streaming)
    mutating func updateLastMessage(content: String, isStreaming: Bool) {
        guard !messages.isEmpty else { return }
        messages[messages.count - 1].content = content
        messages[messages.count - 1].isStreaming = isStreaming
        updatedAt = Date()
    }

    /// Gets messages formatted for the LLM context
    func contextMessages(limit: Int = 20) -> [ChatMessage] {
        // Get recent messages, excluding tool messages for context
        let relevantMessages = messages.filter { $0.role != .tool }
        return Array(relevantMessages.suffix(limit))
    }

    /// Auto-generates a title from the first user message
    var autoTitle: String {
        if let title = title, !title.isEmpty {
            return title
        }
        if let firstUserMessage = messages.first(where: { $0.role == .user }) {
            let preview = String(firstUserMessage.content.prefix(30))
            return preview + (firstUserMessage.content.count > 30 ? "..." : "")
        }
        return "Neues Gespräch"
    }

    /// Formatted date for display
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: updatedAt)
    }
}

// MARK: - Tool Call Result

struct ToolCallResult: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let toolName: String
    let parameters: [String: String]
    let resultText: String
    let success: Bool
    let timestamp: Date

    init(
        id: UUID = UUID(),
        toolName: String,
        parameters: [String: String] = [:],
        resultText: String,
        success: Bool = true,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.toolName = toolName
        self.parameters = parameters
        self.resultText = resultText
        self.success = success
        self.timestamp = timestamp
    }
}
