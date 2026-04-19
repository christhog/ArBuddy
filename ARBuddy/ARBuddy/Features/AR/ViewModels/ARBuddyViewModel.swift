//
//  ARBuddyViewModel.swift
//  ARBuddy
//
//  Created by Chris Greve on 19.01.26.
//

import Foundation
import RealityKit
import Combine
import UIKit

enum PlacementMode {
    case automatic  // Bestehende Auto-Detection
    case manual     // User hat getippt
}

/// Button representation for country selection on AR globe
struct CountryButton: Identifiable {
    let id: String  // ISO-Code
    var screenPosition: CGPoint
    var isVisible: Bool
    var clusteredWith: [String]?  // Wenn geclustert, welche anderen Länder
}

@MainActor
class ARBuddyViewModel: ObservableObject {
    @Published var modelEntity: ModelEntity?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentBuddy: Buddy?

    // Placement State
    @Published var placementMode: PlacementMode = .automatic
    @Published var manualPosition: SIMD3<Float>?
    @Published var placementError: String?

    // AR Globe State
    @Published var isGlobeVisible = false
    @Published var isBuddyVisible = true
    @Published var selectedCountryCode: String?
    @Published var countryProgress: [CountryProgress] = []
    @Published var isLoadingCountryProgress = false
    @Published var selectedCountryForRotation: String?

    // Lip Sync State
    @Published var isLipSyncActive = false
    @Published var lipSyncMode: LipSyncMode = .disabled
    @Published var modelCapabilities: ModelCapabilities = .none

    // Country Button Overlay State
    @Published var countryButtons: [CountryButton] = []
    @Published var currentGlobeScale: Float = 0.3
    @Published var showClusterPopup: Bool = false
    @Published var clusteredCountryCodes: [String] = []

    /// Available countries for rotation picker (sorted by German name)
    var availableCountries: [(code: String, name: String)] {
        CountryCenters.allCountries
    }

    private let assetService = BuddyAssetService.shared
    private let lipSyncService = LipSyncService.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Observe buddy changes from SupabaseService
        SupabaseService.shared.$selectedBuddy
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buddy in
                guard let buddy = buddy else { return }
                Task {
                    await self?.loadBuddy(buddy)
                }
            }
            .store(in: &cancellables)

        // Observe lip sync state
        lipSyncService.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.isLipSyncActive = state.isActive
            }
            .store(in: &cancellables)

        lipSyncService.$currentMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                self?.lipSyncMode = mode
            }
            .store(in: &cancellables)

        lipSyncService.$modelCapabilities
            .receive(on: DispatchQueue.main)
            .sink { [weak self] capabilities in
                self?.modelCapabilities = capabilities
            }
            .store(in: &cancellables)
    }

    /// Loads the buddy model for AR display
    func loadBuddy(_ buddy: Buddy) async {
        guard buddy.id != currentBuddy?.id else {
            isLoading = false  // Already loaded, clear loading state
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let entity = try await assetService.loadModelEntity(for: buddy)

            modelEntity = entity
            currentBuddy = buddy
            print("Loaded buddy model: \(buddy.name)")
        } catch {
            errorMessage = error.localizedDescription
            print("Failed to load buddy: \(error)")

            // Create fallback cube
            modelEntity = createFallbackEntity()
        }

        isLoading = false
    }

    /// Loads the currently selected buddy
    func loadSelectedBuddy() async {
        isLoading = true

        guard let buddy = SupabaseService.shared.selectedBuddy else {
            // Try to get selected buddy
            do {
                if let buddy = try await SupabaseService.shared.getSelectedBuddy() {
                    await loadBuddy(buddy)
                } else {
                    // No buddy selected, use fallback only after confirming none exists
                    modelEntity = createFallbackEntity()
                    isLoading = false
                }
            } catch {
                print("Failed to get selected buddy: \(error)")
                modelEntity = createFallbackEntity()
                isLoading = false
            }
            return
        }

        await loadBuddy(buddy)
    }

    /// Creates a fallback cube entity when no buddy is available
    private func createFallbackEntity() -> ModelEntity {
        let mesh = MeshResource.generateBox(size: 0.1, cornerRadius: 0.005)
        // Use direct RGB color (blue) instead of system color to avoid UIKit dependency
        let blueColor = SimpleMaterial.Color(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
        let material = SimpleMaterial(color: blueColor, roughness: 0.15, isMetallic: true)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        return entity
    }

    /// Pre-downloads the buddy model
    func preloadBuddy(_ buddy: Buddy) async {
        do {
            _ = try await assetService.ensureModelCached(for: buddy)
            print("Preloaded buddy: \(buddy.name)")
        } catch {
            print("Failed to preload buddy: \(error)")
        }
    }

    // MARK: - Placement Methods

    /// Places buddy at manual position from tap
    func placeAt(_ position: SIMD3<Float>) {
        manualPosition = position
        placementMode = .manual
        placementError = nil
    }

    /// Resets to automatic placement mode
    func resetPlacement() {
        placementMode = .automatic
        manualPosition = nil
        placementError = nil
    }

    /// Sets placement error message
    func setPlacementError(_ message: String) {
        placementError = message
    }

    // MARK: - Globe Methods

    /// Loads country progress for the globe overlay
    func loadCountryProgress() async {
        isLoadingCountryProgress = true

        do {
            let statistics = try await SupabaseService.shared.fetchCountryStatistics()
            countryProgress = statistics
                .map { CountryProgress(from: $0) }
                .sorted { $0.totalQuestsCompleted > $1.totalQuestsCompleted }
        } catch {
            print("Failed to load country progress for AR globe: \(error)")
            countryProgress = []
        }

        isLoadingCountryProgress = false
    }

    /// Gets country progress for a specific country code
    func getCountryProgress(for countryCode: String) -> CountryProgress? {
        countryProgress.first { $0.id == countryCode }
    }

    /// Selects a country and shows its popup
    func selectCountry(_ countryCode: String) {
        selectedCountryCode = countryCode
    }

    /// Clears the selected country
    func clearSelectedCountry() {
        selectedCountryCode = nil
    }

    /// Toggles globe visibility
    func toggleGlobe() {
        isGlobeVisible.toggle()
        if isGlobeVisible {
            Task {
                await loadCountryProgress()
            }
        } else {
            clearSelectedCountry()
        }
    }

    /// Toggles buddy visibility
    func toggleBuddy() {
        isBuddyVisible.toggle()
    }

    /// Triggers globe rotation to show the specified country
    func rotateGlobeToCountry(_ countryCode: String) {
        selectedCountryForRotation = countryCode
    }

    // MARK: - Country Button Methods

    /// Shows cluster popup with multiple countries
    func showClusterPopupWith(_ countryCodes: [String]) {
        clusteredCountryCodes = countryCodes
        showClusterPopup = true
    }

    /// Dismisses the cluster popup
    func dismissClusterPopup() {
        showClusterPopup = false
        clusteredCountryCodes = []
    }

    /// Updates the current globe scale (called from ARViewContainer)
    func updateGlobeScale(_ scale: Float) {
        currentGlobeScale = scale
    }

    // MARK: - Lip Sync Methods

    /// Configures lip sync for the current buddy model
    func configureLipSync(for entity: ModelEntity) async {
        let capabilities = await lipSyncService.inspectModel(entity)
        await MainActor.run {
            lipSyncService.configure(for: entity, capabilities: capabilities)
        }
        print("[ARBuddyVM] Lip sync configured: \(capabilities.recommendedLipSyncMode.displayName)")
    }

    /// Starts lip sync animation with viseme events
    /// - Parameters:
    ///   - visemes: Array of viseme events with timing
    ///   - audioStartTime: The exact time audio playback started (for sync). If nil, uses current time.
    func startLipSync(with visemes: [VisemeEvent], audioStartTime: Date? = nil) {
        lipSyncService.startAnimation(with: visemes, audioStartTime: audioStartTime)
    }

    /// Starts amplitude-based lip sync (fallback)
    func startAmplitudeLipSync() {
        lipSyncService.startAmplitudeMode()
    }

    /// Updates audio amplitude for amplitude-based lip sync
    func updateLipSyncAmplitude(_ amplitude: Float) {
        lipSyncService.updateAmplitude(amplitude)
    }

    /// Stops lip sync animation
    func stopLipSync() {
        lipSyncService.stopAnimation()
    }

    /// Sets the lip sync mode manually
    func setLipSyncMode(_ mode: LipSyncMode) {
        lipSyncService.setMode(mode)
    }

    /// Inspects the current buddy model for lip sync capabilities
    func inspectCurrentModel() async -> ModelInspectionResult? {
        guard let buddy = currentBuddy else { return nil }

        do {
            let result = try await assetService.inspectModelCapabilities(for: buddy)
            print(result.description)
            return result
        } catch {
            print("[ARBuddyVM] Failed to inspect model: \(error)")
            return nil
        }
    }
}
