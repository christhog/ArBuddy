//
//  ChatView.swift
//  ARBuddy
//
//  Created by Claude on 12.04.26.
//

import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @EnvironmentObject var supabaseService: SupabaseService
    @Environment(\.dismiss) private var dismiss

    /// Initialize with an external ViewModel (shared with MiniChatOverlay)
    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status banner (cloud indicator or model status if needed)
            if viewModel.isUsingCloud {
                CloudStatusBanner(viewModel: viewModel)
            } else if !viewModel.canChat {
                ModelStatusBanner(viewModel: viewModel)
            }

            // Messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            ChatMessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    // Scroll to bottom when new message arrives
                    if let lastMessage = viewModel.messages.last {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Input area
            ChatInputView(viewModel: viewModel)
        }
        .navigationTitle(supabaseService.selectedBuddy?.name ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task {
                            await viewModel.newConversation()
                        }
                    } label: {
                        Label("Neues Gespräch", systemImage: "plus.message")
                    }

                    Button {
                        viewModel.toggleTTS()
                    } label: {
                        Label(
                            viewModel.isSpeaking ? "Sprache aus" : "Sprache an",
                            systemImage: viewModel.isSpeaking ? "speaker.slash" : "speaker.wave.2"
                        )
                    }

                    Divider()

                    Button(role: .destructive) {
                        Task {
                            await viewModel.clearChat()
                        }
                    } label: {
                        Label("Verlauf löschen", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Fehler", isPresented: .init(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
    }
}

// MARK: - Cloud Status Banner

private struct CloudStatusBanner: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        HStack {
            Image(systemName: "cloud")
                .foregroundStyle(.blue)

            Text("Cloud KI (Claude)")
                .font(.subheadline)

            Spacer()

            if viewModel.isGenerating {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.1))
    }
}

// MARK: - Model Status Banner

private struct ModelStatusBanner: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)

                Text(statusText)
                    .font(.subheadline)

                Spacer()

                if case .downloading(let progress) = viewModel.modelState {
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if case .downloading(let progress) = viewModel.modelState {
                ProgressView(value: progress)
                    .tint(.blue)
            }

            if viewModel.modelState == .notDownloaded {
                Button {
                    Task {
                        await viewModel.downloadModel()
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                        Text("Modell herunterladen (\(viewModel.recommendedModel.formattedSize))")
                    }
                    .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if viewModel.modelState == .downloaded {
                Button {
                    Task {
                        await viewModel.loadModel()
                    }
                } label: {
                    HStack {
                        Image(systemName: "play.circle")
                        Text("Modell laden")
                    }
                    .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
    }

    private var statusIcon: String {
        switch viewModel.modelState {
        case .notDownloaded:
            return "arrow.down.circle"
        case .downloading:
            return "arrow.down.circle"
        case .downloaded:
            return "checkmark.circle"
        case .loading:
            return "gear"
        case .loaded:
            return "checkmark.circle.fill"
        case .unloading:
            return "gear"
        case .error:
            return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch viewModel.modelState {
        case .notDownloaded:
            return .secondary
        case .downloading:
            return .blue
        case .downloaded:
            return .green
        case .loading, .unloading:
            return .orange
        case .loaded:
            return .green
        case .error:
            return .red
        }
    }

    private var statusText: String {
        viewModel.modelState.displayText
    }
}

// MARK: - Chat Message Row

private struct ChatMessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.isUser {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                // Message bubble
                Text(message.content)
                    .font(.body)
                    .foregroundStyle(message.isUser ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(message.isUser ? Color.blue : Color(.secondarySystemBackground))
                    )

                // Streaming indicator
                if message.isStreaming {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Schreibt...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Tool call results
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    ForEach(toolCalls) { toolCall in
                        ToolCallBadge(result: toolCall)
                    }
                }

                // Timestamp
                Text(message.formattedTime)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !message.isUser {
                Spacer(minLength: 60)
            }
        }
    }
}

// MARK: - Tool Call Badge

private struct ToolCallBadge: View {
    let result: ToolCallResult

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.success ? .green : .red)
                .font(.caption)

            Text(result.toolName)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color(.tertiarySystemBackground))
        )
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ChatView(viewModel: ChatViewModel())
            .environmentObject(SupabaseService.shared)
    }
}
