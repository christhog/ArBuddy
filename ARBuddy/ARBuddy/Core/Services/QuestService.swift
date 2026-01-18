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

    @Published var activeQuests: [Quest] = []
    @Published var completedQuestIds: Set<UUID> = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let questTemplates: [QuestTemplate] = [
        QuestTemplate(
            titleFormat: "Entdecke %@",
            descriptionFormat: "Besuche %@ und entdecke diesen interessanten Ort.",
            type: .visit,
            difficulty: .easy,
            baseXP: 50
        ),
        QuestTemplate(
            titleFormat: "Fotografiere %@",
            descriptionFormat: "Mache ein Foto von %@ und halte den Moment fest.",
            type: .photo,
            difficulty: .medium,
            baseXP: 75
        ),
        QuestTemplate(
            titleFormat: "AR-Erlebnis bei %@",
            descriptionFormat: "Starte ein AR-Erlebnis bei %@ und interagiere mit deinem Buddy.",
            type: .ar,
            difficulty: .medium,
            baseXP: 100
        ),
        QuestTemplate(
            titleFormat: "Quiz über %@",
            descriptionFormat: "Beantworte Fragen über %@ und teste dein Wissen.",
            type: .trivia,
            difficulty: .hard,
            baseXP: 125
        )
    ]

    private init() {
        loadCompletedQuests()
    }

    /// Generiert Quests basierend auf POIs
    func generateQuests(for pois: [POI]) -> [Quest] {
        var quests: [Quest] = []

        for poi in pois {
            // Jeder POI bekommt IMMER einen Quiz-Quest + einen zufälligen anderen
            let triviaTemplate = questTemplates.first { $0.type == .trivia }!
            let otherTemplates = questTemplates.filter { $0.type != .trivia }
            let randomOther = otherTemplates.randomElement()!

            // Quiz-Quest hinzufügen
            let triviaQuest = Quest(
                id: UUID(),
                title: String(format: triviaTemplate.titleFormat, poi.name),
                description: String(format: triviaTemplate.descriptionFormat, poi.name),
                type: triviaTemplate.type,
                difficulty: determineDifficulty(for: poi, baseTemplate: triviaTemplate),
                xpReward: triviaTemplate.baseXP,
                poiId: poi.id,
                latitude: poi.latitude,
                longitude: poi.longitude,
                radius: 50.0,
                isActive: true
            )
            quests.append(triviaQuest)

            // Zufälliger anderer Quest
            let otherQuest = Quest(
                id: UUID(),
                title: String(format: randomOther.titleFormat, poi.name),
                description: String(format: randomOther.descriptionFormat, poi.name),
                type: randomOther.type,
                difficulty: determineDifficulty(for: poi, baseTemplate: randomOther),
                xpReward: randomOther.baseXP,
                poiId: poi.id,
                latitude: poi.latitude,
                longitude: poi.longitude,
                radius: 50.0,
                isActive: true
            )
            quests.append(otherQuest)
        }

        activeQuests = quests.filter { !completedQuestIds.contains($0.id) }
        return quests
    }

    /// Prüft ob ein Quest abgeschlossen werden kann (User ist am Ort)
    func canCompleteQuest(_ quest: Quest, userLocation: CLLocation) -> Bool {
        guard let questLocation = quest.location else { return false }

        let questCLLocation = CLLocation(
            latitude: questLocation.latitude,
            longitude: questLocation.longitude
        )

        let distance = userLocation.distance(from: questCLLocation)
        return distance <= quest.radius
    }

    /// Markiert ein Quest als abgeschlossen
    func completeQuest(_ quest: Quest) -> Int {
        completedQuestIds.insert(quest.id)
        activeQuests.removeAll { $0.id == quest.id }
        saveCompletedQuests()
        return quest.calculatedXPReward
    }

    /// Gibt alle Quests für einen bestimmten POI zurück
    func quests(for poiId: UUID) -> [Quest] {
        return activeQuests.filter { $0.poiId == poiId }
    }

    /// Gibt die nächsten Quests basierend auf Entfernung zurück
    func nearbyQuests(from location: CLLocation, limit: Int = 10) -> [Quest] {
        return activeQuests
            .compactMap { quest -> (Quest, Double)? in
                guard let questLocation = quest.location else { return nil }
                let distance = location.distance(from: CLLocation(
                    latitude: questLocation.latitude,
                    longitude: questLocation.longitude
                ))
                return (quest, distance)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    // MARK: - Private Helpers

    private func determineDifficulty(for poi: POI, baseTemplate: QuestTemplate) -> QuestDifficulty {
        // Kultur und Landmarks sind oft interessanter = höhere Schwierigkeit für mehr XP
        switch poi.category {
        case .culture, .landmark:
            return baseTemplate.difficulty == .easy ? .medium : baseTemplate.difficulty
        case .nature:
            return baseTemplate.difficulty
        default:
            return .easy
        }
    }

    private func saveCompletedQuests() {
        let ids = completedQuestIds.map { $0.uuidString }
        UserDefaults.standard.set(ids, forKey: "completedQuestIds")
    }

    private func loadCompletedQuests() {
        if let ids = UserDefaults.standard.stringArray(forKey: "completedQuestIds") {
            completedQuestIds = Set(ids.compactMap { UUID(uuidString: $0) })
        }
    }
}

// MARK: - Quest Template

private struct QuestTemplate {
    let titleFormat: String
    let descriptionFormat: String
    let type: QuestType
    let difficulty: QuestDifficulty
    let baseXP: Int
}
