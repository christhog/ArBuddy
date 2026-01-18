//
//  POI.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import Foundation
import CoreLocation

// MARK: - POI Category

enum POICategory: String, Codable, CaseIterable {
    case landmark = "landmark"
    case nature = "nature"
    case culture = "culture"
    case food = "food"
    case shop = "shop"
    case entertainment = "entertainment"
    case other = "other"

    var iconName: String {
        switch self {
        case .landmark: return "building.columns"
        case .nature: return "leaf"
        case .culture: return "theatermasks"
        case .food: return "fork.knife"
        case .shop: return "bag"
        case .entertainment: return "gamecontroller"
        case .other: return "mappin"
        }
    }
}

// MARK: - POI Progress

struct POIProgress: Codable, Equatable {
    var visitCompleted: Bool
    var photoCompleted: Bool
    var arCompleted: Bool
    var quizCompleted: Bool
    var quizScore: Int?

    init(
        visitCompleted: Bool = false,
        photoCompleted: Bool = false,
        arCompleted: Bool = false,
        quizCompleted: Bool = false,
        quizScore: Int? = nil
    ) {
        self.visitCompleted = visitCompleted
        self.photoCompleted = photoCompleted
        self.arCompleted = arCompleted
        self.quizCompleted = quizCompleted
        self.quizScore = quizScore
    }

    /// Returns true if all quest types are completed
    var isFullyCompleted: Bool {
        visitCompleted && photoCompleted && arCompleted && quizCompleted
    }

    /// Number of completed quest types (0-4)
    var completedCount: Int {
        var count = 0
        if visitCompleted { count += 1 }
        if photoCompleted { count += 1 }
        if arCompleted { count += 1 }
        if quizCompleted { count += 1 }
        return count
    }

    /// Progress as a percentage (0.0 - 1.0)
    var progressPercentage: Double {
        Double(completedCount) / 4.0
    }
}

// MARK: - Game Events

struct MysteryGameEvent: Codable {
    let story: String
    let clues: [String]
    let solution: String
}

struct TreasureGameEvent: Codable {
    let riddle: String
    let nextPoiHint: String
}

struct TimetravelGameEvent: Codable {
    let era: String
    let historicalFacts: [String]
    let whatIf: String
}

// MARK: - POI

struct POI: Identifiable, Codable {
    let id: UUID
    var name: String
    var description: String
    var category: POICategory
    var latitude: Double
    var longitude: Double
    var imageURL: String?
    var quests: [UUID]
    var createdAt: Date

    // Address info
    var street: String?
    var city: String?

    // AI-generated content
    var aiCategory: String?
    var aiFacts: [String]?

    // Quiz availability
    var hasQuiz: Bool

    // User progress (optional, set when user is logged in)
    var userProgress: POIProgress?

    // Geoapify categories for internal use
    var geoapifyCategories: [String]?

    init(
        id: UUID = UUID(),
        name: String,
        description: String,
        category: POICategory,
        latitude: Double,
        longitude: Double,
        imageURL: String? = nil,
        quests: [UUID] = [],
        createdAt: Date = Date(),
        street: String? = nil,
        city: String? = nil,
        aiCategory: String? = nil,
        aiFacts: [String]? = nil,
        hasQuiz: Bool = false,
        userProgress: POIProgress? = nil,
        geoapifyCategories: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.imageURL = imageURL
        self.quests = quests
        self.createdAt = createdAt
        self.street = street
        self.city = city
        self.aiCategory = aiCategory
        self.aiFacts = aiFacts
        self.hasQuiz = hasQuiz
        self.userProgress = userProgress
        self.geoapifyCategories = geoapifyCategories
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func distance(from location: CLLocation) -> CLLocationDistance {
        let poiLocation = CLLocation(latitude: latitude, longitude: longitude)
        return location.distance(from: poiLocation)
    }

    /// Returns a formatted address string
    var formattedAddress: String? {
        var parts: [String] = []
        if let street = street { parts.append(street) }
        if let city = city { parts.append(city) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Returns the completion status icon for map markers
    var completionIcon: String {
        guard let progress = userProgress else { return "" }
        if progress.isFullyCompleted {
            return "checkmark.circle.fill"
        } else if progress.completedCount > 0 {
            return "circle.lefthalf.filled"
        }
        return ""
    }
}

// MARK: - POICategory String Conversion

extension POICategory {
    /// Initialisiert POICategory aus einem String (von der Edge Function)
    init(fromString string: String) {
        switch string.lowercased() {
        case "landmark":
            self = .landmark
        case "culture":
            self = .culture
        case "nature":
            self = .nature
        case "food":
            self = .food
        case "entertainment":
            self = .entertainment
        case "shop":
            self = .shop
        default:
            self = .other
        }
    }

    /// Geoapify-Kategorien für diese POI-Kategorie
    var geoapifyCategories: [String] {
        switch self {
        case .landmark:
            return ["tourism.sights", "tourism.attraction", "heritage"]
        case .nature:
            return ["leisure.park", "natural", "leisure.garden"]
        case .culture:
            return ["entertainment.museum", "entertainment.culture", "entertainment.gallery"]
        case .food:
            return ["catering.restaurant", "catering.cafe", "catering.bar"]
        case .shop:
            return ["commercial.supermarket", "commercial.shopping_mall", "commercial.shop"]
        case .entertainment:
            return ["entertainment.cinema", "entertainment.zoo", "entertainment.theme_park"]
        case .other:
            return ["tourism.information"]
        }
    }
}
