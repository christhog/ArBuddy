//
//  QuestsViewModel.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import Foundation
import CoreLocation
import Combine

// MARK: - POI Quest Group

struct POIQuestGroup: Identifiable {
    let poiId: UUID
    let poiName: String
    var quests: [Quest]
    var completedCount: Int

    var id: UUID { poiId }
}

@MainActor
class QuestsViewModel: ObservableObject {
    @Published var quests: [Quest] = []
    @Published var filteredQuests: [Quest] = []
    @Published var selectedFilter: QuestType?
    @Published var isLoading = false
    @Published var completionMessage: String?
    @Published var earnedXP: Int = 0
    @Published var poiProgress: [UUID: POIProgress] = [:]

    private let questService = QuestService.shared

    init() {
        updateQuests()
    }

    /// Quests grouped by POI
    var questsByPOI: [POIQuestGroup] {
        // Group quests by their POI ID
        var groups: [UUID: POIQuestGroup] = [:]

        for quest in filteredQuests {
            guard let poiId = quest.poiId else { continue }

            if var group = groups[poiId] {
                group.quests.append(quest)
                groups[poiId] = group
            } else {
                groups[poiId] = POIQuestGroup(
                    poiId: poiId,
                    poiName: quest.title.components(separatedBy: " - ").first ?? quest.title,
                    quests: [quest],
                    completedCount: poiProgress[poiId]?.completedCount ?? 0
                )
            }
        }

        // Sort groups by POI name
        return Array(groups.values).sorted { $0.poiName < $1.poiName }
    }

    /// Aktualisiert die Quest-Liste
    func updateQuests() {
        quests = questService.activeQuests
        applyFilter()
    }

    /// Aktualisiert den POI-Fortschritt aus den Kartendaten
    func updatePOIProgress(_ progress: [UUID: POIProgress]) {
        self.poiProgress = progress
    }

    /// Setzt den Filter
    func setFilter(_ filter: QuestType?) {
        selectedFilter = filter
        applyFilter()
    }

    /// Wendet den aktuellen Filter an
    private func applyFilter() {
        if let filter = selectedFilter {
            filteredQuests = quests.filter { $0.type == filter }
        } else {
            filteredQuests = quests
        }
    }

    /// Sortiert Quests nach Entfernung
    func sortByDistance(from location: CLLocation) {
        filteredQuests = questService.nearbyQuests(from: location, limit: 50)
        if let filter = selectedFilter {
            filteredQuests = filteredQuests.filter { $0.type == filter }
        }
    }

    /// Versucht ein Quest abzuschließen
    func attemptCompletion(of quest: Quest, userLocation: CLLocation) -> Bool {
        guard questService.canCompleteQuest(quest, userLocation: userLocation) else {
            completionMessage = "Du bist noch nicht nah genug am Ziel!"
            return false
        }

        let xp = questService.completeQuest(quest)
        earnedXP = xp
        completionMessage = "Quest abgeschlossen! +\(xp) XP"
        updateQuests()

        return true
    }

    /// Berechnet Distanz zu einem Quest
    func distance(to quest: Quest, from location: CLLocation?) -> String? {
        guard let location = location,
              let questCoord = quest.location else { return nil }

        let questLocation = CLLocation(
            latitude: questCoord.latitude,
            longitude: questCoord.longitude
        )
        let distance = location.distance(from: questLocation)

        if distance < 1000 {
            return "\(Int(distance)) m"
        } else {
            return String(format: "%.1f km", distance / 1000)
        }
    }

    /// Prüft ob User im Radius ist
    func isInRange(of quest: Quest, userLocation: CLLocation?) -> Bool {
        guard let location = userLocation else { return false }
        return questService.canCompleteQuest(quest, userLocation: location)
    }

    func clearCompletionMessage() {
        completionMessage = nil
        earnedXP = 0
    }
}
