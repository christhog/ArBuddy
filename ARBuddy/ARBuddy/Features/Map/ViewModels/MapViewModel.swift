//
//  MapViewModel.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import Foundation
import CoreLocation
import SwiftUI
import Combine

@MainActor
class MapViewModel: ObservableObject {
    @Published var pois: [POI] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var selectedPOI: POI?
    @Published var lastLoadedLocation: CLLocation?

    private let poiService = POIService.shared
    private let questService = QuestService.shared
    private var questCompletedCancellable: AnyCancellable?
    private var isLoadingPOIs = false
    private var pendingReloadLocation: CLLocation?

    init() {
        questCompletedCancellable = NotificationCenter.default
            .publisher(for: .questCompleted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                Task { @MainActor in
                    await self?.refreshAfterQuestCompletion(poiId: notification.object as? UUID)
                }
            }
    }

    /// Lädt POIs für die aktuelle Position
    func loadPOIs(near location: CLLocation, radius: Double = 5000) async {
        print("[MapViewModel] loadPOIs called - isLoadingPOIs: \(isLoadingPOIs)")

        // Race Condition verhindern - aber Reload vormerken
        if isLoadingPOIs {
            print("[MapViewModel] Load in progress, scheduling pending reload")
            pendingReloadLocation = location
            return
        }

        // Verhindere zu häufiges Neuladen
        if let lastLocation = lastLoadedLocation {
            let distance = location.distance(from: lastLocation)
            if distance < 100 {
                print("[MapViewModel] Skipping load - distance too small: \(distance)m")
                return
            }
        }

        isLoadingPOIs = true

        isLoading = true
        errorMessage = nil

        do {
            let fetchedPOIs = try await poiService.fetchPOIs(
                near: location.coordinate,
                radius: radius
            )

            print("[MapViewModel] Fetched \(fetchedPOIs.count) POIs")
            self.pois = fetchedPOIs
            self.lastLoadedLocation = location

            // Generiere Quests für die geladenen POIs
            _ = questService.generateQuests(for: fetchedPOIs)

        } catch {
            print("[MapViewModel] Error loading POIs: \(error)")
            self.errorMessage = error.localizedDescription
        }

        isLoading = false
        isLoadingPOIs = false

        // Falls während des Ladens ein Reload angefordert wurde
        if let pendingLocation = pendingReloadLocation {
            print("[MapViewModel] Processing pending reload")
            pendingReloadLocation = nil
            await loadPOIs(near: pendingLocation, radius: radius)
        }
    }

    /// Gibt die Quests für einen POI zurück
    func quests(for poi: POI) -> [Quest] {
        return questService.quests(for: poi.id)
    }

    /// Berechnet die Distanz zum POI
    func distance(to poi: POI, from location: CLLocation?) -> String? {
        guard let location = location else { return nil }

        let distance = poi.distance(from: location)

        if distance < 1000 {
            return "\(Int(distance)) m"
        } else {
            return String(format: "%.1f km", distance / 1000)
        }
    }

    /// Filtert POIs nach Kategorie (legacy method)
    func pois(for category: POICategory?) -> [POI] {
        guard let category = category else { return pois }
        return pois.filter { $0.category == category }
    }

    /// Filtert POIs nach Kategorie und Fortschritt
    func filteredPOIs(category: POICategory?, progressFilter: POIProgressFilter) -> [POI] {
        var filtered = pois

        // Filter by category
        if let category = category {
            filtered = filtered.filter { $0.category == category }
        }

        // Filter by progress
        switch progressFilter {
        case .all:
            break
        case .completed:
            filtered = filtered.filter { $0.userProgress?.isFullyCompleted == true }
        case .inProgress:
            filtered = filtered.filter {
                guard let progress = $0.userProgress else { return false }
                return progress.completedCount > 0 && !progress.isFullyCompleted
            }
        case .notStarted:
            filtered = filtered.filter {
                $0.userProgress == nil || $0.userProgress?.completedCount == 0
            }
        }

        return filtered
    }

    /// Gibt Statistiken über die POIs zurück
    var poiStatistics: (total: Int, completed: Int, inProgress: Int, notStarted: Int) {
        let completed = pois.filter { $0.userProgress?.isFullyCompleted == true }.count
        let inProgress = pois.filter {
            guard let progress = $0.userProgress else { return false }
            return progress.completedCount > 0 && !progress.isFullyCompleted
        }.count
        let notStarted = pois.count - completed - inProgress

        return (pois.count, completed, inProgress, notStarted)
    }

    /// Aktualisiert den Fortschritt eines POIs
    func updatePOIProgress(poiId: UUID, progress: POIProgress) {
        if let index = pois.firstIndex(where: { $0.id == poiId }) {
            pois[index].userProgress = progress

            // Auch im Service aktualisieren
            Task {
                await poiService.updatePOIProgress(poiId: poiId, progress: progress)
            }
        }
    }

    /// Erzwingt ein Neuladen der POIs
    func forceReload() async {
        await poiService.clearCache()
        lastLoadedLocation = nil
    }

    /// Aktualisiert POIs nach Quest-Abschluss
    func refreshAfterQuestCompletion(poiId: UUID?) async {
        print("[MapViewModel] refreshAfterQuestCompletion called - poiId: \(poiId?.uuidString ?? "nil")")
        print("[MapViewModel] Current POI count: \(pois.count)")

        guard let location = lastLoadedLocation else {
            print("[MapViewModel] No lastLoadedLocation, skipping refresh")
            return
        }

        print("[MapViewModel] Clearing cache and reloading POIs")

        // Cache invalidieren
        await poiService.clearCache()

        // lastLoadedLocation temporär nil setzen für Reload
        let savedLocation = lastLoadedLocation
        lastLoadedLocation = nil

        // POIs neu laden
        await loadPOIs(near: location)

        print("[MapViewModel] After refresh - POI count: \(pois.count)")

        // Falls loadPOIs fehlgeschlagen, Location wiederherstellen
        if lastLoadedLocation == nil {
            print("[MapViewModel] Restoring saved location")
            lastLoadedLocation = savedLocation
        }
    }
}
