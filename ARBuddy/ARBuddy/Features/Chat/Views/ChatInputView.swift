//
//  ChatInputView.swift
//  ARBuddy
//
//  Created by Claude on 12.04.26.
//

import SwiftUI

struct ChatInputView: View {
    @ObservedObject var viewModel: ChatViewModel
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            // Voice transcription preview (when listening)
            if viewModel.isListening {
                VoiceTranscriptionPreview(
                    text: viewModel.transcribedText,
                    onCancel: {
                        viewModel.cancelListening()
                    }
                )
            }

            // Input bar
            HStack(spacing: 12) {
                // Text field
                HStack {
                    TextField("Nachricht...", text: $viewModel.inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
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
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(.secondarySystemBackground))
                )

                // Voice input button
                VoiceInputButton(
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
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? .blue : .gray)
                }
                .disabled(!canSend)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
        }
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

// MARK: - Voice Transcription Preview

private struct VoiceTranscriptionPreview: View {
    let text: String
    let onCancel: () -> Void

    var body: some View {
        HStack {
            // Waveform animation
            WaveformAnimation()
                .frame(width: 40, height: 20)

            // Transcribed text
            Text(text.isEmpty ? "Ich höre zu..." : text)
                .font(.subheadline)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .lineLimit(2)

            Spacer()

            // Cancel button
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }
}

// MARK: - Waveform Animation

private struct WaveformAnimation: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(Color.blue)
                    .frame(width: 3)
                    .scaleEffect(y: animating ? CGFloat.random(in: 0.3...1.0) : 0.3, anchor: .center)
                    .animation(
                        Animation.easeInOut(duration: 0.3)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.1),
                        value: animating
                    )
            }
        }
        .onAppear {
            animating = true
        }
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Spacer()
        ChatInputView(viewModel: ChatViewModel())
    }
}
