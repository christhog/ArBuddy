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
