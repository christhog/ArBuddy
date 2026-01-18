//
//  CountryStatistics.swift
//  ARBuddy
//
//  Created by Chris Greve on 18.01.26.
//

import Foundation

/// Statistics for a user's progress in a specific country
/// Loaded from the user_country_statistics Supabase view
struct CountryStatistics: Codable, Identifiable {
    let country: String              // "Germany", "Austria", etc.
    let totalPoisInCountry: Int      // All POIs in this country
    let completedPois: Int           // POIs where user has at least 1 quest completed
    let visitsCompleted: Int
    let photosCompleted: Int
    let arCompleted: Int
    let quizzesCompleted: Int

    var id: String { country }

    enum CodingKeys: String, CodingKey {
        case country
        case totalPoisInCountry = "total_pois_in_country"
        case completedPois = "completed_pois"
        case visitsCompleted = "visits_completed"
        case photosCompleted = "photos_completed"
        case arCompleted = "ar_completed"
        case quizzesCompleted = "quizzes_completed"
    }

    // MARK: - Computed Properties

    /// Total quests completed across all POIs in this country
    var totalQuestsCompleted: Int {
        visitsCompleted + photosCompleted + arCompleted + quizzesCompleted
    }

    /// Total possible quests (each POI has 4 quest types)
    var totalPossibleQuests: Int {
        totalPoisInCountry * 4
    }

    /// Overall progress as a percentage (0.0 to 1.0)
    var overallProgress: Double {
        guard totalPossibleQuests > 0 else { return 0 }
        return Double(totalQuestsCompleted) / Double(totalPossibleQuests)
    }
}
