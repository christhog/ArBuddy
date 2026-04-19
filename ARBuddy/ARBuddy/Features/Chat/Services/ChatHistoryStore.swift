//
//  ChatHistoryStore.swift
//  ARBuddy
//
//  Created by Claude on 12.04.26.
//

import Foundation
import Combine

// MARK: - Chat History Store

/// Local storage for chat history
actor ChatHistoryStore {
    static let shared = ChatHistoryStore()

    private let fileManager = FileManager.default
    private let storageDirectory: URL
    private let conversationsFile: URL

    private var conversations: [ChatConversation] = []
    private var currentConversationId: UUID?

    private init() {
        // Setup storage directory
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        storageDirectory = documentsURL.appendingPathComponent("ChatHistory", isDirectory: true)
        conversationsFile = storageDirectory.appendingPathComponent("conversations.json")

        // Create directory if needed
        try? fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        // Load existing conversations
        Task {
            await loadConversations()
        }
    }

    // MARK: - Conversation Management

    /// Gets or creates the current conversation
    func getCurrentConversation() -> ChatConversation {
        if let id = currentConversationId,
           let conversation = conversations.first(where: { $0.id == id }) {
            return conversation
        }

        // Create new conversation
        let newConversation = ChatConversation()
        conversations.insert(newConversation, at: 0)
        currentConversationId = newConversation.id
        return newConversation
    }

    /// Starts a new conversation
    func startNewConversation() -> ChatConversation {
        let newConversation = ChatConversation()
        conversations.insert(newConversation, at: 0)
        currentConversationId = newConversation.id
        Task {
            await saveConversations()
        }
        return newConversation
    }

    /// Gets all conversations
    func getAllConversations() -> [ChatConversation] {
        conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Gets a specific conversation
    func getConversation(id: UUID) -> ChatConversation? {
        conversations.first { $0.id == id }
    }

    /// Sets the current conversation
    func setCurrentConversation(id: UUID) {
        if conversations.contains(where: { $0.id == id }) {
            currentConversationId = id
        }
    }

    /// Deletes a conversation
    func deleteConversation(id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentConversationId == id {
            currentConversationId = conversations.first?.id
        }
        Task {
            await saveConversations()
        }
    }

    // MARK: - Message Management

    /// Adds a message to the current conversation
    func addMessage(_ message: ChatMessage) {
        guard let index = conversations.firstIndex(where: { $0.id == currentConversationId }) else {
            // Create new conversation if none exists
            var newConversation = ChatConversation()
            newConversation.addMessage(message)
            conversations.insert(newConversation, at: 0)
            currentConversationId = newConversation.id
            return
        }

        conversations[index].addMessage(message)
        Task {
            await saveConversations()
        }
    }

    /// Updates the last message in the current conversation (for streaming)
    func updateLastMessage(content: String, isStreaming: Bool) {
        guard let index = conversations.firstIndex(where: { $0.id == currentConversationId }) else {
            return
        }

        conversations[index].updateLastMessage(content: content, isStreaming: isStreaming)
    }

    /// Gets recent messages for context
    func getRecentMessages(limit: Int = 10) -> [ChatMessage] {
        guard let conversation = conversations.first(where: { $0.id == currentConversationId }) else {
            return []
        }
        return Array(conversation.messages.suffix(limit))
    }

    /// Gets messages for the current conversation
    func getCurrentMessages() -> [ChatMessage] {
        guard let conversation = conversations.first(where: { $0.id == currentConversationId }) else {
            return []
        }
        return conversation.messages
    }

    // MARK: - Persistence

    private func loadConversations() async {
        guard fileManager.fileExists(atPath: conversationsFile.path) else {
            print("[ChatHistory] No existing conversations file")
            return
        }

        do {
            let data = try Data(contentsOf: conversationsFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            conversations = try decoder.decode([ChatConversation].self, from: data)
            currentConversationId = conversations.first?.id
            print("[ChatHistory] Loaded \(conversations.count) conversations")
        } catch {
            print("[ChatHistory] Failed to load conversations: \(error)")
        }
    }

    private func saveConversations() async {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(conversations)
            try data.write(to: conversationsFile)
            print("[ChatHistory] Saved \(conversations.count) conversations")
        } catch {
            print("[ChatHistory] Failed to save conversations: \(error)")
        }
    }

    /// Clears all chat history
    func clearAllHistory() {
        conversations = []
        currentConversationId = nil
        try? fileManager.removeItem(at: conversationsFile)
        print("[ChatHistory] History cleared")
    }

    /// Returns the total storage size used by chat history
    func storageSize() -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: conversationsFile.path),
              let size = attributes[.size] as? Int64 else {
            return 0
        }
        return size
    }
}

// MARK: - Convenience Extensions

extension ChatHistoryStore {
    /// Formats the context for the LLM from recent messages
    func buildContextPrompt(limit: Int = 10) -> String {
        let messages = getRecentMessages(limit: limit)

        var context = ""
        for message in messages {
            switch message.role {
            case .user:
                context += "User: \(message.content)\n"
            case .assistant:
                context += "Assistant: \(message.content)\n"
            case .system, .tool:
                // Skip system and tool messages in context
                continue
            }
        }

        return context
    }
}
