//
//  QuestsViewModel.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import Foundation
import CoreLocation
import Combine

// MARK: - Quest Category Filter

enum QuestCategoryFilter: String, CaseIterable {
    case poi = "POI-Quests"
    case world = "World-Quests"

    var displayName: String { rawValue }
}

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
    @Published var selectedStatusFilter: QuestStatusFilter = .open
    @Published var selectedCategoryFilter: QuestCategoryFilter = .poi
    @Published var isLoading = false
    @Published var completionMessage: String?
    @Published var earnedXP: Int = 0
    @Published var poiProgress: [UUID: POIProgress] = [:]

    private let questService = QuestService.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        setupQuestServiceBinding()
        updateQuests()
    }

    /// Sets up Combine bindings to observe QuestService changes
    private func setupQuestServiceBinding() {
        // Observe allQuests changes from QuestService
        questService.$allQuests
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateQuests()
            }
            .store(in: &cancellables)

        // Observe poiQuests changes for category filtering
        questService.$poiQuests
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateQuests()
            }
            .store(in: &cancellables)

        // Observe worldQuests changes
        questService.$worldQuests
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateQuests()
            }
            .store(in: &cancellables)
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
        quests = questService.allQuests
        applyFilter()
    }

    /// Aktualisiert den POI-Fortschritt aus den Kartendaten
    func updatePOIProgress(_ progress: [UUID: POIProgress]) {
        self.poiProgress = progress
        applyFilter()
    }

    /// Setzt den Typ-Filter
    func setFilter(_ filter: QuestType?) {
        selectedFilter = filter
        applyFilter()
    }

    /// Setzt den Status-Filter
    func setStatusFilter(_ filter: QuestStatusFilter) {
        selectedStatusFilter = filter
        applyFilter()
    }

    /// Setzt den Kategorie-Filter (POI/World)
    func setCategoryFilter(_ filter: QuestCategoryFilter) {
        selectedCategoryFilter = filter
        // Reset type filter when switching to World (type filters not shown there)
        if filter == .world {
            selectedFilter = nil
        }
        applyFilter()
    }

    /// Wendet den aktuellen Filter an
    private func applyFilter() {
        var result = quests

        // Category filter (POI/World)
        switch selectedCategoryFilter {
        case .poi:
            // POI quests: have a poiId AND are not AR type
            result = result.filter { $0.poiId != nil && $0.type != .ar }
        case .world:
            // World quests: AR type (regardless of poiId) or no poiId
            result = result.filter { $0.type == .ar || $0.poiId == nil }
        }

        // Type filter
        if let filter = selectedFilter {
            result = result.filter { $0.type == filter }
        }

        // Status filter
        switch selectedStatusFilter {
        case .all:
            break
        case .open:
            result = result.filter { quest in
                !isQuestCompleted(quest)
            }
        case .completed:
            result = result.filter { quest in
                isQuestCompleted(quest)
            }
        }

        filteredQuests = result
    }

    /// Prüft ob ein Quest abgeschlossen ist
    func isQuestCompleted(_ quest: Quest) -> Bool {
        // Check by quest ID in completedQuestIds
        if questService.completedQuestIds.contains(quest.id) {
            return true
        }

        // Check by POI progress
        if let poiId = quest.poiId, let progress = poiProgress[poiId] {
            switch quest.type {
            case .visit: return progress.visitCompleted
            case .photo: return progress.photoCompleted
            case .ar: return progress.arCompleted
            case .quiz, .trivia: return progress.quizCompleted
            }
        }

        return false
    }

    /// Sortiert Quests nach Entfernung
    func sortByDistance(from location: CLLocation) {
        // Use legacy quests filtered by distance
        guard let questLocation = quests.first?.location else {
            applyFilter()
            return
        }

        // Sort quests by distance
        filteredQuests = quests.sorted { quest1, quest2 in
            guard let loc1 = quest1.location, let loc2 = quest2.location else { return false }
            let dist1 = location.distance(from: CLLocation(latitude: loc1.latitude, longitude: loc1.longitude))
            let dist2 = location.distance(from: CLLocation(latitude: loc2.latitude, longitude: loc2.longitude))
            return dist1 < dist2
        }

        if let filter = selectedFilter {
            filteredQuests = filteredQuests.filter { $0.type == filter }
        }
        switch selectedStatusFilter {
        case .all: break
        case .open:
            filteredQuests = filteredQuests.filter { !isQuestCompleted($0) }
        case .completed:
            filteredQuests = filteredQuests.filter { isQuestCompleted($0) }
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
