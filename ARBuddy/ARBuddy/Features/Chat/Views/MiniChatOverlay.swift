//
//  MiniChatOverlay.swift
//  ARBuddy
//
//  Created by Claude on 15.04.26.
//

import SwiftUI

/// A compact chat overlay that displays on top of the 3D buddy,
/// showing recent messages and a simplified input field.
struct MiniChatOverlay: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var showFullChat: Bool

    /// Maximum number of messages to display
    private let maxVisibleMessages = 5

    var body: some View {
        VStack(spacing: 0) {
            // Header with expand button
            headerView

            // Messages area
            messagesArea

            // Compact input
            CompactChatInput(viewModel: viewModel)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            // Status indicator
            if viewModel.isGenerating {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Denkt nach...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.isSpeaking {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Text("Spricht...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Expand button
            Button {
                showFullChat = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(
                        Circle()
                            .fill(Color(.tertiarySystemBackground))
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Messages

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(recentMessages) { message in
                        MiniChatBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 180)
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onAppear {
                scrollToBottom(proxy: proxy)
            }
        }
    }

    /// Returns the most recent user/assistant messages to display (system and tool messages are hidden)
    private var recentMessages: [ChatMessage] {
        let displayable = viewModel.messages.filter { $0.role == .user || $0.role == .assistant }
        return Array(displayable.suffix(maxVisibleMessages))
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastMessage = recentMessages.last {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }
}

// MARK: - Mini Chat Bubble

/// A compact message bubble for the mini chat overlay
private struct MiniChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if message.isUser {
                Spacer(minLength: 40)
            }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 2) {
                // Message content
                Text(message.content)
                    .font(.system(size: 14))
                    .foregroundStyle(message.isUser ? .white : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(message.isUser ? Color.blue : Color(.tertiarySystemBackground))
                    )

                // Streaming indicator
                if message.isStreaming {
                    HStack(spacing: 3) {
                        TypingIndicator()
                        Text("...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !message.isUser {
                Spacer(minLength: 40)
            }
        }
    }
}

// MARK: - Typing Indicator

/// A simple typing animation for streaming messages
private struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 4, height: 4)
                    .scaleEffect(animating ? 1.0 : 0.5)
                    .animation(
                        Animation.easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear {
            animating = true
        }
    }
}

// MARK: - Compact Chat Input

/// A simplified input view for the mini chat overlay
struct CompactChatInput: View {
    @ObservedObject var viewModel: ChatViewModel
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Text field
            HStack(spacing: 8) {
                TextField("Nachricht...", text: $viewModel.inputText)
                    .font(.system(size: 14))
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
                    .disabled(viewModel.isListening || !viewModel.canChat)
                    .onSubmit {
                        sendMessage()
                    }

                // Clear button
                if !viewModel.inputText.isEmpty {
                    Button {
                        viewModel.inputText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.tertiarySystemBackground))
            )

            // Voice button (compact)
            CompactVoiceButton(
                isListening: viewModel.isListening,
                isDisabled: !viewModel.canChat,
                onTapDown: {
                    Task {
                        await viewModel.startListening()
                    }
                },
                onTapUp: {
                    Task {
                        await viewModel.stopListeningAndSend()
                    }
                }
            )

            // Send button
            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(canSend ? .blue : .gray.opacity(0.5))
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground).opacity(0.5))
    }

    private var canSend: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !viewModel.isGenerating &&
        viewModel.canChat
    }

    private func sendMessage() {
        guard canSend else { return }
        isTextFieldFocused = false
        Task {
            await viewModel.sendMessage()
        }
    }
}

// MARK: - Compact Voice Button

/// A smaller voice input button for the mini chat
private struct CompactVoiceButton: View {
    let isListening: Bool
    let isDisabled: Bool
    let onTapDown: () -> Void
    let onTapUp: () -> Void

    @State private var isPressed = false
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Pulse animation when listening
            if isListening {
                Circle()
                    .fill(Color.red.opacity(0.3))
                    .frame(width: 36, height: 36)
                    .scaleEffect(pulseScale)
                    .animation(
                        Animation.easeInOut(duration: 1.0)
                            .repeatForever(autoreverses: true),
                        value: pulseScale
                    )
                    .onAppear {
                        pulseScale = 1.3
                    }
                    .onDisappear {
                        pulseScale = 1.0
                    }
            }

            // Main button
            Circle()
                .fill(buttonColor)
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: isListening ? "waveform" : "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .scaleEffect(isPressed ? 0.9 : 1.0)
        }
        .opacity(isDisabled ? 0.5 : 1.0)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isDisabled, !isPressed else { return }
                    isPressed = true
                    onTapDown()
                }
                .onEnded { _ in
                    guard !isDisabled, isPressed else { return }
                    isPressed = false
                    onTapUp()
                }
        )
    }

    private var buttonColor: Color {
        if isDisabled {
            return .gray
        }
        return isListening ? .red : .blue
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.gray.opacity(0.3)
            .ignoresSafeArea()

        VStack {
            Spacer()
            MiniChatOverlay(
                viewModel: ChatViewModel(),
                showFullChat: .constant(false)
            )
        }
    }
}
