//
//  CompletedQuestsViewModel.swift
//  ARBuddy
//
//  Created by Chris Greve on 27.01.26.
//

import Foundation
import Combine

@MainActor
class CompletedQuestsViewModel: ObservableObject {
    @Published var entries: [CompletedQuestEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let supabaseService = SupabaseService.shared

    func fetchCompletedQuests() async {
        guard let userId = supabaseService.currentUser?.id else {
            errorMessage = "Nicht eingeloggt"
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            entries = try await supabaseService.fetchCompletedQuests(userId: userId)
        } catch {
            errorMessage = "Fehler beim Laden: \(error.localizedDescription)"
            print("Failed to fetch completed quests: \(error)")
        }

        isLoading = false
    }
}
