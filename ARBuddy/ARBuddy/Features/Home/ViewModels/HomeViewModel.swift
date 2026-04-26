//
//  HomeViewModel.swift
//  ARBuddy
//
//  Created by Chris Greve on 12.04.26.
//

import Foundation
import RealityKit
import Combine

@MainActor
class HomeViewModel: ObservableObject {
    @Published var currentBuddy: Buddy?
    @Published var modelEntity: ModelEntity?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Listen for buddy changes
        NotificationCenter.default.publisher(for: .buddyChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let buddy = notification.object as? Buddy {
                    Task {
                        await self?.loadBuddy(buddy)
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Load the user's selected buddy
    func loadSelectedBuddy() async {
        isLoading = true
        errorMessage = nil

        do {
            // Fetch buddies from Supabase
            let buddies = try await SupabaseService.shared.fetchBuddies()

            // Get user's selected buddy ID from UserDefaults
            let selectedBuddyId = UserDefaults.standard.string(forKey: "selectedBuddyId")

            // Find the selected buddy or use default
            let resolved: Buddy?
            if let selectedId = selectedBuddyId,
               let uuid = UUID(uuidString: selectedId),
               let selected = buddies.first(where: { $0.id == uuid }) {
                resolved = selected
            } else if let defaultBuddy = buddies.first(where: { $0.isDefault }) {
                resolved = defaultBuddy
            } else {
                resolved = buddies.first
            }

            // Low-RAM guardrail (iPhone <14): swap to Micoo even if the user's
            // persisted choice is Aleda, since 4K body textures OOM the app.
            guard let buddy = SupabaseService.shared.applyLowMemoryGuardrail(to: resolved) else {
                errorMessage = "Kein Buddy gefunden"
                isLoading = false
                return
            }

            await loadBuddy(buddy)

        } catch {
            errorMessage = "Fehler beim Laden: \(error.localizedDescription)"
            isLoading = false
        }
    }

    /// Load a specific buddy model
    func loadBuddy(_ buddy: Buddy) async {
        isLoading = true
        errorMessage = nil
        currentBuddy = buddy

        do {
            let entity = try await BuddyAssetService.shared.loadModelEntity(for: buddy)
            modelEntity = entity
            print("Buddy model loaded: \(buddy.name)")
        } catch {
            errorMessage = "Model konnte nicht geladen werden: \(error.localizedDescription)"
            print("Failed to load buddy model: \(error)")
        }

        isLoading = false
    }
}

// MARK: - Notification Extension

extension Notification.Name {
    static let buddyChanged = Notification.Name("buddyChanged")
}
