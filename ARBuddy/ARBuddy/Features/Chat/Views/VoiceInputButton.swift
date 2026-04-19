//
//  VoiceInputButton.swift
//  ARBuddy
//
//  Created by Claude on 12.04.26.
//

import SwiftUI

struct VoiceInputButton: View {
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
                    .frame(width: 50, height: 50)
                    .scaleEffect(pulseScale)
                    .animation(
                        Animation.easeInOut(duration: 1.0)
                            .repeatForever(autoreverses: true),
                        value: pulseScale
                    )
                    .onAppear {
                        pulseScale = 1.4
                    }
                    .onDisappear {
                        pulseScale = 1.0
                    }
            }

            // Main button
            Circle()
                .fill(buttonColor)
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: isListening ? "waveform" : "mic.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .scaleEffect(isPressed ? 0.9 : 1.0)
                .shadow(color: buttonColor.opacity(0.4), radius: isListening ? 8 : 4)
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
        .accessibilityLabel(isListening ? "Sprachaufnahme beenden" : "Spracheingabe starten")
        .accessibilityHint("Halten um zu sprechen")
    }

    private var buttonColor: Color {
        if isDisabled {
            return .gray
        }
        return isListening ? .red : .blue
    }
}

// MARK: - Animated Microphone Icon

struct AnimatedMicrophoneIcon: View {
    let isActive: Bool

    @State private var waveOffset: CGFloat = 0

    var body: some View {
        ZStack {
            // Microphone base
            Image(systemName: "mic.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)

            // Sound waves when active
            if isActive {
                ForEach(0..<3, id: \.self) { index in
                    SoundWave(index: index, offset: waveOffset)
                }
            }
        }
        .onAppear {
            if isActive {
                withAnimation(Animation.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    waveOffset = 1.0
                }
            }
        }
        .onChange(of: isActive) { _, newValue in
            if newValue {
                withAnimation(Animation.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    waveOffset = 1.0
                }
            } else {
                waveOffset = 0
            }
        }
    }
}

private struct SoundWave: View {
    let index: Int
    let offset: CGFloat

    var body: some View {
        Circle()
            .stroke(Color.white.opacity(0.5 - Double(index) * 0.15), lineWidth: 1.5)
            .frame(width: CGFloat(20 + index * 8), height: CGFloat(20 + index * 8))
            .scaleEffect(1.0 + offset * CGFloat(index + 1) * 0.2)
            .opacity(Double(1.0 - offset))
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 30) {
        HStack(spacing: 20) {
            VoiceInputButton(
                isListening: false,
                isDisabled: false,
                onTapDown: {},
                onTapUp: {}
            )

            VoiceInputButton(
                isListening: true,
                isDisabled: false,
                onTapDown: {},
                onTapUp: {}
            )

            VoiceInputButton(
                isListening: false,
                isDisabled: true,
                onTapDown: {},
                onTapUp: {}
            )
        }

        Text("Normal / Listening / Disabled")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .padding()
}
