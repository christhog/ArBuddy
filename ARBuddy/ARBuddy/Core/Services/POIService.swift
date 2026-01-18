//
//  POIService.swift
//  ARBuddy
//
//  Created by Chris Greve on 16.01.26.
//

import Foundation
import CoreLocation

actor POIService {
    static let shared = POIService()

    private var cache: [String: [POI]] = [:]

    private init() {}

    /// Lädt POIs in einem bestimmten Radius um eine Koordinate (via Supabase Edge Function)
    func fetchPOIs(
        near coordinate: CLLocationCoordinate2D,
        radius: Double = 5000,
        categories: [POICategory] = POICategory.allCases
    ) async throws -> [POI] {
        let cacheKey = "\(coordinate.latitude),\(coordinate.longitude),\(radius)"

        if let cached = cache[cacheKey] {
            return cached
        }

        print("Fetching POIs via Edge Function...")

        // Fetch via Supabase Edge Function
        let edgePOIs = try await SupabaseService.shared.fetchPOIs(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radius: radius
        )

        // Convert EdgePOI to POI
        let pois = edgePOIs.compactMap { edgePOI -> POI? in
            // Parse UUID from string
            guard let id = UUID(uuidString: edgePOI.id) else {
                print("Invalid POI ID: \(edgePOI.id)")
                return nil
            }

            // Convert progress if available
            var progress: POIProgress?
            if let edgeProgress = edgePOI.userProgress {
                progress = POIProgress(
                    visitCompleted: edgeProgress.visitCompleted,
                    photoCompleted: edgeProgress.photoCompleted,
                    arCompleted: edgeProgress.arCompleted,
                    quizCompleted: edgeProgress.quizCompleted,
                    quizScore: edgeProgress.quizScore
                )
            }

            return POI(
                id: id,
                name: edgePOI.name,
                description: edgePOI.description,
                category: POICategory(fromString: edgePOI.category),
                latitude: edgePOI.latitude,
                longitude: edgePOI.longitude,
                imageURL: nil,
                quests: [],
                street: edgePOI.street,
                city: edgePOI.city,
                aiFacts: edgePOI.aiFacts,
                hasQuiz: edgePOI.hasQuiz ?? false,
                userProgress: progress,
                geoapifyCategories: edgePOI.geoapifyCategories
            )
        }

        print("Loaded \(pois.count) POIs")
        cache[cacheKey] = pois

        return pois
    }

    /// Updates progress for a specific POI in the cache
    func updatePOIProgress(poiId: UUID, progress: POIProgress) {
        for (key, var pois) in cache {
            if let index = pois.firstIndex(where: { $0.id == poiId }) {
                pois[index].userProgress = progress
                cache[key] = pois
            }
        }
    }

    /// Clears the cache to force a fresh fetch
    func clearCache() {
        cache.removeAll()
    }

    /// Returns POIs from cache that match a filter
    func getCachedPOIs(filter: POIFilter = .all) -> [POI] {
        let allPOIs = cache.values.flatMap { $0 }

        switch filter {
        case .all:
            return Array(allPOIs)
        case .completed:
            return allPOIs.filter { $0.userProgress?.isFullyCompleted == true }
        case .inProgress:
            return allPOIs.filter {
                guard let progress = $0.userProgress else { return false }
                return progress.completedCount > 0 && !progress.isFullyCompleted
            }
        case .notStarted:
            return allPOIs.filter {
                $0.userProgress == nil || $0.userProgress?.completedCount == 0
            }
        case .category(let category):
            return allPOIs.filter { $0.category == category }
        }
    }
}

// MARK: - POI Filter

enum POIFilter {
    case all
    case completed
    case inProgress
    case notStarted
    case category(POICategory)
}

// MARK: - Errors

enum POIServiceError: LocalizedError {
    case serverError
    case parsingError

    var errorDescription: String? {
        switch self {
        case .serverError:
            return "Server-Fehler beim Laden der POIs"
        case .parsingError:
            return "Fehler beim Verarbeiten der POI-Daten"
        }
    }
}
