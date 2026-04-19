//
//  QuestService.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import Foundation
import CoreLocation
import Combine

@MainActor
class QuestService: ObservableObject {
    static let shared = QuestService()

    // MARK: - Published State

    /// All POI quests loaded from Supabase
    @Published var poiQuests: [POIQuest] = []

    /// All world quests loaded from Supabase
    @Published var worldQuests: [WorldQuest] = []

    /// Set of completed POI quest IDs (cached locally for quick lookup)
    @Published var completedPOIQuestIds: Set<UUID> = []

    /// Set of completed world quest IDs
    @Published var completedWorldQuestIds: Set<UUID> = []

    @Published var isLoading = false
    @Published var errorMessage: String?

    /// Indicates whether quests have been loaded (at least once)
    @Published var isQuestsLoaded = false

    // MARK: - Legacy Support (for backward compatibility)

    @Published var activeQuests: [Quest] = []
    @Published var allQuests: [Quest] = []
    @Published var completedQuestIds: Set<UUID> = []

    // MARK: - Initialization

    private init() {
        loadCompletedQuests()
    }

    // MARK: - POI Quest Loading

    /// Loads POI quests from the edge function response
    func loadPOIQuests(from edgeQuests: [EdgePOIQuest]) {
        let quests = edgeQuests.compactMap { edgeQuest -> POIQuest? in
            guard let id = UUID(uuidString: edgeQuest.id),
                  let poiId = UUID(uuidString: edgeQuest.poiId) else {
                return nil
            }

            return POIQuest(
                id: id,
                poiId: poiId,
                questType: QuestType(rawValue: edgeQuest.questType) ?? .visit,
                title: edgeQuest.title,
                description: edgeQuest.description,
                xpReward: edgeQuest.xpReward,
                difficulty: QuestDifficulty(rawValue: edgeQuest.difficulty) ?? .easy
            )
        }

        poiQuests = quests
        isQuestsLoaded = true
        print("[QuestService] Loaded \(quests.count) POI quests from edge function")

        // Update legacy quest list for backward compatibility
        updateLegacyQuests()
    }

    /// Loads POI quests directly from Supabase for specific POI IDs
    func fetchPOIQuests(for poiIds: [UUID]) async {
        guard !poiIds.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        do {
            let quests = try await SupabaseService.shared.fetchPOIQuests(poiIds: poiIds)
            poiQuests = quests
            isQuestsLoaded = true
            print("[QuestService] Fetched \(quests.count) POI quests from Supabase")
            updateLegacyQuests()
        } catch {
            errorMessage = "Fehler beim Laden der Quests: \(error.localizedDescription)"
            print("[QuestService] Error fetching POI quests: \(error)")
        }

        isLoading = false
    }

    // MARK: - World Quest Loading

    /// Loads world quests near a location
    func fetchWorldQuests(latitude: Double, longitude: Double, radius: Double = 10000) async {
        isLoading = true
        errorMessage = nil

        do {
            let quests = try await SupabaseService.shared.fetchWorldQuests(
                latitude: latitude,
                longitude: longitude,
                radius: radius
            )
            worldQuests = quests
            print("[QuestService] Fetched \(quests.count) world quests")
        } catch {
            errorMessage = "Fehler beim Laden der World-Quests: \(error.localizedDescription)"
            print("[QuestService] Error fetching world quests: \(error)")
        }

        isLoading = false
    }

    /// Loads all active world quests
    func fetchAllActiveWorldQuests() async {
        isLoading = true
        errorMessage = nil

        do {
            let quests = try await SupabaseService.shared.fetchAllActiveWorldQuests()
            worldQuests = quests
            print("[QuestService] Fetched \(quests.count) active world quests")
        } catch {
            errorMessage = "Fehler beim Laden der World-Quests: \(error.localizedDescription)"
            print("[QuestService] Error fetching world quests: \(error)")
        }

        isLoading = false
    }

    // MARK: - Quest Retrieval

    /// Returns POI quests for a specific POI
    func quests(for poiId: UUID) -> [POIQuest] {
        return poiQuests.filter { $0.poiId == poiId }
    }

    /// Returns active (not completed) POI quests for a specific POI
    func activeQuests(for poiId: UUID) -> [POIQuest] {
        return quests(for: poiId).filter { !isQuestCompleted($0) }
    }

    /// Returns active (not completed) world quests
    func activeWorldQuests() -> [WorldQuest] {
        return worldQuests.filter { !completedWorldQuestIds.contains($0.id) }
    }

    /// Checks if a POI quest is completed based on user progress
    func isQuestCompleted(_ quest: POIQuest, userProgress: POIProgress? = nil) -> Bool {
        // First check local cache
        if completedPOIQuestIds.contains(quest.id) {
            return true
        }

        // Then check user progress if available
        guard let progress = userProgress else { return false }

        switch quest.questType {
        case .visit:
            return progress.visitCompleted
        case .photo:
            return progress.photoCompleted
        case .quiz, .trivia:
            return progress.quizCompleted
        case .ar:
            return progress.arCompleted
        }
    }

    /// Returns nearby POI quests sorted by distance
    func nearbyPOIQuests(from location: CLLocation, pois: [POI], limit: Int = 10) -> [(quest: POIQuest, distance: Double)] {
        var questsWithDistance: [(quest: POIQuest, distance: Double)] = []

        for quest in poiQuests {
            guard let poi = pois.first(where: { $0.id == quest.poiId }) else { continue }

            // Skip completed quests
            if isQuestCompleted(quest, userProgress: poi.userProgress) { continue }

            let poiLocation = CLLocation(latitude: poi.latitude, longitude: poi.longitude)
            let distance = location.distance(from: poiLocation)
            questsWithDistance.append((quest: quest, distance: distance))
        }

        return questsWithDistance
            .sorted { $0.distance < $1.distance }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Quest Completion

    /// Marks a POI quest as completed locally
    func markQuestCompleted(_ quest: POIQuest) {
        completedPOIQuestIds.insert(quest.id)
        saveCompletedQuests()
    }

    /// Marks a world quest as completed locally
    func markWorldQuestCompleted(_ quest: WorldQuest) {
        completedWorldQuestIds.insert(quest.id)
        saveCompletedQuests()
    }

    /// Completes a world quest (saves to Supabase and adds XP)
    func completeWorldQuest(_ quest: WorldQuest) async throws -> Int {
        try await SupabaseService.shared.completeWorldQuest(
            worldQuestId: quest.id,
            xpEarned: quest.calculatedXPReward
        )

        markWorldQuestCompleted(quest)
        return quest.calculatedXPReward
    }

    // MARK: - Legacy Support

    /// Updates the legacy quest arrays for backward compatibility
    private func updateLegacyQuests() {
        // Convert POIQuest to legacy Quest format
        allQuests = poiQuests.map { poiQuest in
            Quest(
                id: poiQuest.id,
                title: poiQuest.title,
                description: poiQuest.description ?? "",
                type: poiQuest.questType,
                difficulty: poiQuest.difficulty,
                xpReward: poiQuest.xpReward,
                poiId: poiQuest.poiId,
                latitude: nil,
                longitude: nil,
                radius: 50.0,
                isActive: true,
                createdAt: Date()
            )
        }

        activeQuests = allQuests.filter { !completedQuestIds.contains($0.id) }
    }

    /// Legacy method: Generates quests based on POIs (now loads from Supabase instead)
    @available(*, deprecated, message: "Use loadPOIQuests(from:) instead")
    func generateQuests(for pois: [POI]) -> [Quest] {
        // This method is deprecated - quests are now generated server-side
        // Return empty array or existing quests
        return allQuests
    }

    /// Legacy method: Check if quest can be completed
    func canCompleteQuest(_ quest: Quest, userLocation: CLLocation) -> Bool {
        guard let questLocation = quest.location else { return false }

        let questCLLocation = CLLocation(
            latitude: questLocation.latitude,
            longitude: questLocation.longitude
        )

        let distance = userLocation.distance(from: questCLLocation)
        return distance <= quest.radius
    }

    /// Legacy method: Complete a quest
    func completeQuest(_ quest: Quest) -> Int {
        completedQuestIds.insert(quest.id)
        activeQuests.removeAll { $0.id == quest.id }
        saveCompletedQuests()
        return quest.calculatedXPReward
    }

    /// Legacy method: Get quests for a POI (returns legacy Quest type)
    func legacyQuests(for poiId: UUID) -> [Quest] {
        return allQuests.filter { $0.poiId == poiId }
    }

    // MARK: - Persistence

    private func saveCompletedQuests() {
        // Save POI quest IDs
        let poiIds = completedPOIQuestIds.map { $0.uuidString }
        UserDefaults.standard.set(poiIds, forKey: "completedPOIQuestIds")

        // Save world quest IDs
        let worldIds = completedWorldQuestIds.map { $0.uuidString }
        UserDefaults.standard.set(worldIds, forKey: "completedWorldQuestIds")

        // Legacy support
        let legacyIds = completedQuestIds.map { $0.uuidString }
        UserDefaults.standard.set(legacyIds, forKey: "completedQuestIds")
    }

    private func loadCompletedQuests() {
        // Load POI quest IDs
        if let ids = UserDefaults.standard.stringArray(forKey: "completedPOIQuestIds") {
            completedPOIQuestIds = Set(ids.compactMap { UUID(uuidString: $0) })
        }

        // Load world quest IDs
        if let ids = UserDefaults.standard.stringArray(forKey: "completedWorldQuestIds") {
            completedWorldQuestIds = Set(ids.compactMap { UUID(uuidString: $0) })
        }

        // Legacy support
        if let ids = UserDefaults.standard.stringArray(forKey: "completedQuestIds") {
            completedQuestIds = Set(ids.compactMap { UUID(uuidString: $0) })
        }
    }
}
