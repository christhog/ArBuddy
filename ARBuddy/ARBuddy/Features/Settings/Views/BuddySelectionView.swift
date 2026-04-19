//
//  BuddySelectionView.swift
//  ARBuddy
//
//  Created by Chris Greve on 19.01.26.
//

import SwiftUI

struct BuddySelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var supabaseService: SupabaseService
    @State private var isLoading = false
    @State private var downloadingBuddyId: UUID?
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            if isLoading && supabaseService.availableBuddies.isEmpty {
                ProgressView("Lade Buddies...")
                    .padding(.top, 100)
            } else if supabaseService.availableBuddies.isEmpty {
                ContentUnavailableView(
                    "Keine Buddies verfügbar",
                    systemImage: "figure.stand",
                    description: Text("Es sind noch keine AR-Buddies verfügbar.")
                )
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(supabaseService.availableBuddies) { buddy in
                        BuddyCard(
                            buddy: buddy,
                            isSelected: buddy.id == supabaseService.selectedBuddy?.id,
                            isDownloading: downloadingBuddyId == buddy.id
                        ) {
                            selectBuddy(buddy)
                        }
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Buddy wählen")
        .task {
            await loadBuddies()
        }
        .alert("Fehler", isPresented: .constant(errorMessage != nil)) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func loadBuddies() async {
        guard supabaseService.availableBuddies.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            _ = try await supabaseService.fetchBuddies()
        } catch {
            errorMessage = "Fehler beim Laden der Buddies"
            print("Failed to fetch buddies: \(error)")
        }
    }

    private func selectBuddy(_ buddy: Buddy) {
        guard buddy.id != supabaseService.selectedBuddy?.id else {
            dismiss()
            return
        }

        downloadingBuddyId = buddy.id

        Task {
            do {
                // Ensure model is cached
                _ = try await BuddyAssetService.shared.ensureModelCached(for: buddy)

                // Select buddy in database
                try await supabaseService.selectBuddy(buddy)

                // Save to UserDefaults for quick access
                UserDefaults.standard.set(buddy.id.uuidString, forKey: "selectedBuddyId")

                // Notify listeners about buddy change
                NotificationCenter.default.post(name: .buddyChanged, object: buddy)

                // Dismiss sheet
                await MainActor.run {
                    dismiss()
                }
            } catch {
                errorMessage = "Fehler beim Auswählen des Buddies"
                print("Failed to select buddy: \(error)")
            }

            downloadingBuddyId = nil
        }
    }
}

// MARK: - Buddy Card

struct BuddyCard: View {
    let buddy: Buddy
    let isSelected: Bool
    let isDownloading: Bool
    let onSelect: () -> Void

    @State private var isCached = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 12) {
                // Thumbnail or placeholder
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.systemGray6))
                        .aspectRatio(1, contentMode: .fit)

                    if let thumbnailUrl = buddy.fullThumbnailUrl {
                        AsyncImage(url: thumbnailUrl) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } placeholder: {
                            buddyPlaceholder
                        }
                    } else {
                        buddyPlaceholder
                    }

                    // Download indicator
                    if isDownloading {
                        ZStack {
                            Color.black.opacity(0.5)
                                .clipShape(RoundedRectangle(cornerRadius: 12))

                            ProgressView()
                                .tint(.white)
                        }
                    }

                    // Cached indicator
                    if isCached && !isDownloading {
                        VStack {
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .background(Circle().fill(.white).padding(-2))
                            }
                            Spacer()
                        }
                        .padding(8)
                    }
                }

                // Name and description
                VStack(spacing: 4) {
                    Text(buddy.name)
                        .font(.headline)
                        .foregroundColor(.primary)

                    if let description = buddy.description {
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
            )
        }
        .buttonStyle(.plain)
        .task {
            isCached = await BuddyAssetService.shared.isModelCached(for: buddy)
        }
    }

    private var buddyPlaceholder: some View {
        Image(systemName: "figure.stand")
            .font(.system(size: 50))
            .foregroundColor(.gray)
    }
}

#Preview {
    NavigationStack {
        BuddySelectionView()
            .environmentObject(SupabaseService.shared)
    }
}
