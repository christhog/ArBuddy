//
//  ProgressViewModel.swift
//  ARBuddy
//
//  Created by Chris Greve on 18.01.26.
//

import Foundation
import Combine
import CoreLocation

@MainActor
class ProgressViewModel: ObservableObject {
    @Published var countryProgress: [CountryProgress] = []
    @Published var isLoadingCountries = false
    @Published var userCountryCode: String?
    @Published var userCoordinates: (lat: Double, lon: Double)?

    private var cancellables = Set<AnyCancellable>()
    private let geocoder = CLGeocoder()

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

    /// Detect user's country from their current location
    func detectUserCountry(from location: CLLocation?) async {
        guard let location = location else {
            // Use default coordinates if no location available
            userCountryCode = nil
            userCoordinates = CountryCenters.defaultCenter
            return
        }

        // Store the actual user coordinates
        userCoordinates = (lat: location.coordinate.latitude, lon: location.coordinate.longitude)
        print("[Globe] User location: \(location.coordinate.latitude), \(location.coordinate.longitude)")

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let countryCode = placemarks.first?.isoCountryCode {
                userCountryCode = countryCode
                print("[Globe] Detected country: \(countryCode)")
                // Use country center for centering (more visually pleasing than exact location)
                let center = CountryCenters.center(for: countryCode)
                print("[Globe] Country center: \(center.lat), \(center.lon)")
                userCoordinates = center
            }
        } catch {
            print("Failed to reverse geocode location: \(error)")
            // Keep the actual coordinates if geocoding fails
        }
    }
}
