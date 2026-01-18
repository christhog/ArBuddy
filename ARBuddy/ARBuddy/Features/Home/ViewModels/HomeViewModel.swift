//
//  HomeViewModel.swift
//  ARBuddy
//
//  Created by Chris Greve on 18.01.26.
//

import Foundation
import Combine

@MainActor
class HomeViewModel: ObservableObject {
    @Published var countryProgress: [CountryProgress] = []
    @Published var isLoadingCountries = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Listen for quest completions to refresh country progress
        NotificationCenter.default.publisher(for: .questCompleted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task {
                    await self?.loadCountryProgress()
                }
            }
            .store(in: &cancellables)
    }

    /// Load country progress from Supabase
    func loadCountryProgress() async {
        isLoadingCountries = true

        do {
            let statistics = try await SupabaseService.shared.fetchCountryStatistics()

            // Convert CountryStatistics to CountryProgress
            countryProgress = statistics
                .map { CountryProgress(from: $0) }
                .sorted { $0.totalQuestsCompleted > $1.totalQuestsCompleted }

        } catch {
            print("Failed to load country statistics: \(error)")
            countryProgress = []
        }

        isLoadingCountries = false
    }
}
