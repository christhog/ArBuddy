//
//  CountryProgress.swift
//  ARBuddy
//
//  Created by Chris Greve on 18.01.26.
//

import Foundation

struct CountryProgress: Identifiable {
    let id: String              // ISO country code: "DE", "AT", "CH"
    let countryName: String     // "Deutschland"
    let totalPOIs: Int
    let completedPOIs: Int      // POIs with at least 1 quest completed

    // Quest-based progress
    let visitsCompleted: Int
    let photosCompleted: Int
    let arCompleted: Int
    let quizzesCompleted: Int

    // Computed quest totals
    var totalQuestsCompleted: Int {
        visitsCompleted + photosCompleted + arCompleted + quizzesCompleted
    }

    var totalPossibleQuests: Int {
        totalPOIs * 4
    }

    /// Quest-based completion percentage (quests completed / total possible quests)
    var completionPercentage: Double {
        guard totalPossibleQuests > 0 else { return 0 }
        return Double(totalQuestsCompleted) / Double(totalPossibleQuests)
    }

    var colorIntensity: Double {
        // Scale from 0.1 to 1.0 based on completion
        return max(0.1, completionPercentage)
    }

    /// Estimated XP earned in this country based on quest completions
    /// XP values: Visit = 50, Photo = 75, AR = 100, Quiz = 100
    var estimatedXP: Int {
        let visitXP = visitsCompleted * 50
        let photoXP = photosCompleted * 75
        let arXP = arCompleted * 100
        let quizXP = quizzesCompleted * 100
        return visitXP + photoXP + arXP + quizXP
    }

    /// Formatted label text for globe overlay
    /// Shows "X/Y Quests • Z XP" when progress exists, or "0 Quests" otherwise
    var overlayLabelText: String {
        if totalQuestsCompleted > 0 {
            return "\(totalQuestsCompleted)/\(totalPossibleQuests) Quests • \(estimatedXP) XP"
        } else {
            return "0 Quests"
        }
    }

    /// Generate flag emoji from ISO country code
    var flagEmoji: String {
        let base: UInt32 = 127397
        var emoji = ""
        for scalar in id.uppercased().unicodeScalars {
            if let unicode = UnicodeScalar(base + scalar.value) {
                emoji.append(String(unicode))
            }
        }
        return emoji
    }

    // MARK: - Initializers

    init(
        id: String,
        countryName: String,
        totalPOIs: Int,
        completedPOIs: Int,
        visitsCompleted: Int = 0,
        photosCompleted: Int = 0,
        arCompleted: Int = 0,
        quizzesCompleted: Int = 0
    ) {
        self.id = id
        self.countryName = countryName
        self.totalPOIs = totalPOIs
        self.completedPOIs = completedPOIs
        self.visitsCompleted = visitsCompleted
        self.photosCompleted = photosCompleted
        self.arCompleted = arCompleted
        self.quizzesCompleted = quizzesCompleted
    }

    /// Initialize from CountryStatistics (Supabase data)
    init(from statistics: CountryStatistics) {
        self.id = Self.countryNameToCode(statistics.country) ?? statistics.country
        self.countryName = statistics.country
        self.totalPOIs = statistics.totalPoisInCountry
        self.completedPOIs = statistics.completedPois
        self.visitsCompleted = statistics.visitsCompleted
        self.photosCompleted = statistics.photosCompleted
        self.arCompleted = statistics.arCompleted
        self.quizzesCompleted = statistics.quizzesCompleted
    }

    /// Convert country name to ISO code
    private static func countryNameToCode(_ name: String) -> String? {
        let mapping: [String: String] = [
            "Germany": "DE",
            "Deutschland": "DE",
            "Austria": "AT",
            "Österreich": "AT",
            "Switzerland": "CH",
            "Schweiz": "CH",
            "France": "FR",
            "Frankreich": "FR",
            "Italy": "IT",
            "Italien": "IT",
            "Spain": "ES",
            "Spanien": "ES",
            "Netherlands": "NL",
            "Niederlande": "NL",
            "Belgium": "BE",
            "Belgien": "BE",
            "Poland": "PL",
            "Polen": "PL",
            "Czech Republic": "CZ",
            "Czechia": "CZ",
            "Tschechien": "CZ",
            "Denmark": "DK",
            "Dänemark": "DK",
            "United Kingdom": "GB",
            "Großbritannien": "GB",
            "United States": "US",
            "USA": "US",
            "Vereinigte Staaten": "US"
        ]
        return mapping[name]
    }
}

// MARK: - Sample Data

extension CountryProgress {
    static let sampleData: [CountryProgress] = [
        CountryProgress(
            id: "DE",
            countryName: "Deutschland",
            totalPOIs: 12,
            completedPOIs: 5,
            visitsCompleted: 5,
            photosCompleted: 3,
            arCompleted: 2,
            quizzesCompleted: 1
        ),
        CountryProgress(
            id: "AT",
            countryName: "Österreich",
            totalPOIs: 4,
            completedPOIs: 2,
            visitsCompleted: 2,
            photosCompleted: 1,
            arCompleted: 0,
            quizzesCompleted: 0
        ),
        CountryProgress(
            id: "CH",
            countryName: "Schweiz",
            totalPOIs: 3,
            completedPOIs: 1,
            visitsCompleted: 1,
            photosCompleted: 0,
            arCompleted: 0,
            quizzesCompleted: 0
        )
    ]
}
