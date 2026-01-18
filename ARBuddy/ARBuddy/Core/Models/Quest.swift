//
//  Quest.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import Foundation
import CoreLocation

enum QuestType: String, Codable, CaseIterable {
    case visit = "visit"
    case photo = "photo"
    case ar = "ar"
    case trivia = "trivia"
}

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
}

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
