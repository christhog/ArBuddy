//
//  CountryProgressService.swift
//  ARBuddy
//
//  Created by Chris Greve on 18.01.26.
//

import Foundation
import Combine

@MainActor
class CountryProgressService: ObservableObject {
    static let shared = CountryProgressService()

    @Published var countryProgress: [CountryProgress] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private init() {}

    /// Fetch country progress from Supabase
    func loadCountryProgress() async {
        isLoading = true
        errorMessage = nil

        do {
            let statistics = try await SupabaseService.shared.fetchCountryStatistics()

            // Convert CountryStatistics to CountryProgress
            countryProgress = statistics
                .map { CountryProgress(from: $0) }
                .sorted { $0.totalQuestsCompleted > $1.totalQuestsCompleted }

        } catch {
            print("Failed to load country statistics: \(error)")
            errorMessage = "Länder-Fortschritt konnte nicht geladen werden"
            countryProgress = []
        }

        isLoading = false
    }

    /// Clear the current progress
    func clearProgress() {
        countryProgress = []
    }
}
