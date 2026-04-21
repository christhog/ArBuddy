//
//  HomeView.swift
//  ARBuddy
//
//  Created by Chris Greve on 12.04.26.
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var supabaseService: SupabaseService
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var chatViewModel = ChatViewModel()
    @State private var showSettings = false
    @State private var showFullChat = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: [
                        Color(.systemBackground),
                        Color(.systemGray6)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                // Buddy Preview (full screen)
                VStack(spacing: 0) {
                    ZStack {
                        if viewModel.isLoading {
                            ProgressView()
                                .scaleEffect(1.5)
                        } else if let error = viewModel.errorMessage {
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.title)
                                    .foregroundStyle(.orange)
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            BuddyPreviewView(
                                modelEntity: viewModel.modelEntity,
                                backgroundColor: .clear,
                                allowsRotation: true
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Mini Chat Overlay at bottom
                VStack {
                    Spacer()
                    MiniChatOverlay(
                        viewModel: chatViewModel,
                        showFullChat: $showFullChat
                    )
                }

                #if DEBUG
                // Emotion + mocap debug overlays — triggers facial
                // expressions / switches the active mocap clip. Release
                // builds strip the whole stack.
                VStack(spacing: 4) {
                    EmotionDebugBar()
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                    MocapDebugBar()
                        .padding(.horizontal, 8)
                    Spacer()
                }
                #endif
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showFullChat) {
                NavigationStack {
                    ChatView(viewModel: chatViewModel)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    showFullChat = false
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                }
            }
            .task {
                await viewModel.loadSelectedBuddy()
            }
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(SupabaseService.shared)
}

#if DEBUG
/// Horizontal scroll of small buttons that fire each emotion/expression on the
/// active buddy. Purely a dev affordance — hidden in release builds.
private struct EmotionDebugBar: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("😀",  { FacialExpressionService.shared.setExpression(.happy) })
                chip("😂",  { FacialExpressionService.shared.setExpression(.laughter) })
                chip("😢",  { FacialExpressionService.shared.setExpression(.sad) })
                chip("😔",  { FacialExpressionService.shared.setExpression(.melancholy) })
                chip("😠",  { FacialExpressionService.shared.setExpression(.angry) })
                chip("😲",  { FacialExpressionService.shared.setExpression(.surprised) })
                chip("😱",  { FacialExpressionService.shared.setExpression(.fear) })
                chip("🤢",  { FacialExpressionService.shared.setExpression(.disgust) })
                chip("🤔",  { FacialExpressionService.shared.setExpression(.thinking) })
                chip("🤨",  { FacialExpressionService.shared.setExpression(.skeptical) })
                chip("😯",  { FacialExpressionService.shared.setExpression(.wonder) })
                chip("Brow L", { FacialExpressionService.shared.raiseEyebrow(.left) })
                chip("Brow R", { FacialExpressionService.shared.raiseEyebrow(.right) })
                chip("Brow ↑↑", { FacialExpressionService.shared.raiseEyebrow(.both) })
                chip("Eye Roll", { FacialExpressionService.shared.eyeRoll() })
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func chip(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Debug-only mocap clip switcher. Renders one chip per available
/// `MocapClip` and calls `BuddyMocapService.shared.switchClip(_:)` so
/// we can compare takes live without rebuilding. Hidden in release.
private struct MocapDebugBar: View {
    @State private var selected: MocapClip = .default

    var body: some View {
        HStack(spacing: 6) {
            Text("Idle")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(MocapClip.allCases, id: \.self) { clip in
                Button {
                    selected = clip
                    BuddyMocapService.shared.switchClip(clip)
                } label: {
                    Text(clip.displayName)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            selected == clip
                                ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                                : AnyShapeStyle(.ultraThinMaterial),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}
#endif
