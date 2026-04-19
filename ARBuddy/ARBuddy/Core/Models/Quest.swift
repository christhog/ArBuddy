//
//  Quest.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import Foundation
import CoreLocation

// MARK: - Quest Status Filter

enum QuestStatusFilter: String, CaseIterable {
    case all = "all"
    case open = "open"
    case completed = "completed"

    var displayName: String {
        switch self {
        case .all: return "Alle"
        case .open: return "Offen"
        case .completed: return "Abgeschlossen"
        }
    }
}

// MARK: - Quest Category

enum QuestCategory: String, Codable, CaseIterable {
    case poi = "poi"       // POI-bound quests (visit, photo, quiz)
    case world = "world"   // AR experiences / area-based quests
}

// MARK: - Quest Type

enum QuestType: String, Codable, CaseIterable {
    case visit = "visit"
    case photo = "photo"
    case quiz = "quiz"
    case ar = "ar"
    case trivia = "trivia"  // Legacy alias for quiz

    var displayName: String {
        switch self {
        case .visit: return "Entdecken"
        case .photo: return "Fotografieren"
        case .quiz, .trivia: return "Quiz"
        case .ar: return "AR-Erlebnis"
        }
    }

    var iconName: String {
        switch self {
        case .visit: return "mappin.and.ellipse"
        case .photo: return "camera"
        case .quiz, .trivia: return "questionmark.circle"
        case .ar: return "arkit"
        }
    }
}

// MARK: - Quest Difficulty

enum QuestDifficulty: String, Codable, CaseIterable {
    case easy = "easy"
    case medium = "medium"
    case hard = "hard"

    var xpMultiplier: Double {
        switch self {
        case .easy: return 1.0
        case .medium: return 1.5
        case .hard: return 2.0
        }
    }

    var displayName: String {
        switch self {
        case .easy: return "Leicht"
        case .medium: return "Mittel"
        case .hard: return "Schwer"
        }
    }
}

// MARK: - POI Quest (from Supabase)

struct POIQuest: Identifiable, Codable, Equatable {
    let id: UUID
    let poiId: UUID
    let questType: QuestType
    let title: String
    let description: String?
    let xpReward: Int
    let difficulty: QuestDifficulty

    enum CodingKeys: String, CodingKey {
        case id
        case poiId
        case questType
        case title
        case description
        case xpReward
        case difficulty
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        poiId = try container.decode(UUID.self, forKey: .poiId)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        xpReward = try container.decode(Int.self, forKey: .xpReward)

        // Decode questType from string
        let questTypeString = try container.decode(String.self, forKey: .questType)
        questType = QuestType(rawValue: questTypeString) ?? .visit

        // Decode difficulty from string
        let difficultyString = try container.decode(String.self, forKey: .difficulty)
        difficulty = QuestDifficulty(rawValue: difficultyString) ?? .easy
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(poiId, forKey: .poiId)
        try container.encode(questType.rawValue, forKey: .questType)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(xpReward, forKey: .xpReward)
        try container.encode(difficulty.rawValue, forKey: .difficulty)
    }

    init(
        id: UUID = UUID(),
        poiId: UUID,
        questType: QuestType,
        title: String,
        description: String? = nil,
        xpReward: Int = 50,
        difficulty: QuestDifficulty = .easy
    ) {
        self.id = id
        self.poiId = poiId
        self.questType = questType
        self.title = title
        self.description = description
        self.xpReward = xpReward
        self.difficulty = difficulty
    }

    /// Calculated XP reward based on difficulty
    var calculatedXPReward: Int {
        return Int(Double(xpReward) * difficulty.xpMultiplier)
    }
}

// MARK: - World Quest (AR experiences / area-based)

struct WorldQuest: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let description: String?
    let questType: String
    let xpReward: Int
    let difficulty: QuestDifficulty
    let centerLatitude: Double?
    let centerLongitude: Double?
    let radiusMeters: Double?
    let isActive: Bool
    var linkedPOIIds: [UUID]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case questType = "quest_type"
        case xpReward = "xp_reward"
        case difficulty
        case centerLatitude = "center_latitude"
        case centerLongitude = "center_longitude"
        case radiusMeters = "radius_meters"
        case isActive = "is_active"
        case linkedPOIIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        questType = try container.decode(String.self, forKey: .questType)
        xpReward = try container.decode(Int.self, forKey: .xpReward)
        centerLatitude = try container.decodeIfPresent(Double.self, forKey: .centerLatitude)
        centerLongitude = try container.decodeIfPresent(Double.self, forKey: .centerLongitude)
        radiusMeters = try container.decodeIfPresent(Double.self, forKey: .radiusMeters)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        linkedPOIIds = try container.decodeIfPresent([UUID].self, forKey: .linkedPOIIds)

        // Decode difficulty from string
        let difficultyString = try container.decode(String.self, forKey: .difficulty)
        difficulty = QuestDifficulty(rawValue: difficultyString) ?? .medium
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(questType, forKey: .questType)
        try container.encode(xpReward, forKey: .xpReward)
        try container.encode(difficulty.rawValue, forKey: .difficulty)
        try container.encodeIfPresent(centerLatitude, forKey: .centerLatitude)
        try container.encodeIfPresent(centerLongitude, forKey: .centerLongitude)
        try container.encodeIfPresent(radiusMeters, forKey: .radiusMeters)
        try container.encode(isActive, forKey: .isActive)
        try container.encodeIfPresent(linkedPOIIds, forKey: .linkedPOIIds)
    }

    init(
        id: UUID = UUID(),
        title: String,
        description: String? = nil,
        questType: String = "ar",
        xpReward: Int = 100,
        difficulty: QuestDifficulty = .medium,
        centerLatitude: Double? = nil,
        centerLongitude: Double? = nil,
        radiusMeters: Double? = nil,
        isActive: Bool = true,
        linkedPOIIds: [UUID]? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.questType = questType
        self.xpReward = xpReward
        self.difficulty = difficulty
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.radiusMeters = radiusMeters
        self.isActive = isActive
        self.linkedPOIIds = linkedPOIIds
    }

    /// Location coordinate for the center of the quest area
    var centerLocation: CLLocationCoordinate2D? {
        guard let lat = centerLatitude, let lon = centerLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Calculated XP reward based on difficulty
    var calculatedXPReward: Int {
        return Int(Double(xpReward) * difficulty.xpMultiplier)
    }
}

// MARK: - Legacy Quest (for backward compatibility)

struct Quest: Identifiable, Codable {
    let id: UUID
    var title: String
    var description: String
    var type: QuestType
    var difficulty: QuestDifficulty
    var xpReward: Int
    var poiId: UUID?
    var latitude: Double?
    var longitude: Double?
    var radius: Double
    var isActive: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        description: String,
        type: QuestType,
        difficulty: QuestDifficulty = .easy,
        xpReward: Int = 50,
        poiId: UUID? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        radius: Double = 50.0,
        isActive: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.type = type
        self.difficulty = difficulty
        self.xpReward = xpReward
        self.poiId = poiId
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.isActive = isActive
        self.createdAt = createdAt
    }

    var location: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var calculatedXPReward: Int {
        return Int(Double(xpReward) * difficulty.xpMultiplier)
    }
}
