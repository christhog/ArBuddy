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

    /// Generates a cache key that rounds coordinates to ~11m precision (4 decimal places)
    /// This ensures that nearby locations hit the same cache
    private func cacheKey(for coordinate: CLLocationCoordinate2D, radius: Double) -> String {
        // Round to 4 decimal places (~11m precision)
        let roundedLat = (coordinate.latitude * 10000).rounded() / 10000
        let roundedLon = (coordinate.longitude * 10000).rounded() / 10000
        return "\(roundedLat),\(roundedLon),\(radius)"
    }

    /// Lädt POIs in einem bestimmten Radius um eine Koordinate (via Supabase Edge Function)
    /// - Parameters:
    ///   - coordinate: Die Koordinate um die herum gesucht wird
    ///   - radius: Der Suchradius in Metern (Standard: 5000m)
    ///   - categories: Die zu suchenden Kategorien
    ///   - forceRefresh: Wenn true, wird Geoapify aufgerufen um neue POIs zu entdecken
    func fetchPOIs(
        near coordinate: CLLocationCoordinate2D,
        radius: Double = 5000,
        categories: [POICategory] = POICategory.allCases,
        forceRefresh: Bool = false
    ) async throws -> [POI] {
        let key = cacheKey(for: coordinate, radius: radius)

        if let cached = cache[key], !forceRefresh {
            print("[POIService] Cache hit for key: \(key) (\(cached.count) POIs)")
            return cached
        }

        print("Fetching POIs via Edge Function (forceRefresh: \(forceRefresh))...")

        // Fetch via Supabase Edge Function (includes quests)
        // skipGeoapify = !forceRefresh (only call Geoapify on force refresh)
        let result = try await SupabaseService.shared.fetchPOIsWithQuests(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radius: radius,
            skipGeoapify: !forceRefresh
        )

        // Convert EdgePOI to POI
        let pois = convertEdgePOIsToPOIs(result.pois)

        // Load quests into QuestService
        await MainActor.run {
            QuestService.shared.loadPOIQuests(from: result.quests)
        }

        print("[POIService] Loaded \(pois.count) POIs with \(result.quests.count) quests, caching with key: \(key)")
        cache[key] = pois

        return pois
    }

    /// Lädt POIs nur aus der Datenbank (ohne Geoapify API-Aufruf)
    /// Verwendet für Pre-Fetching beim App-Start
    func fetchPOIsFromDatabase(
        near coordinate: CLLocationCoordinate2D,
        radius: Double = 5000
    ) async throws -> [POI] {
        let key = cacheKey(for: coordinate, radius: radius)

        if let cached = cache[key] {
            print("[POIService] Pre-fetch cache hit for key: \(key) (\(cached.count) POIs)")
            return cached
        }

        print("[POIService] Pre-fetching POIs from database only...")

        // Fetch from database only (skipGeoapify = true) - includes quests
        let result = try await SupabaseService.shared.fetchPOIsWithQuests(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radius: radius,
            skipGeoapify: true
        )

        // Convert EdgePOI to POI
        let pois = convertEdgePOIsToPOIs(result.pois)

        // Load quests into QuestService
        await MainActor.run {
            QuestService.shared.loadPOIQuests(from: result.quests)
        }

        print("[POIService] Pre-fetched \(pois.count) POIs with \(result.quests.count) quests from database, caching with key: \(key)")
        cache[key] = pois

        return pois
    }

    /// Converts EdgePOI array to POI array
    private func convertEdgePOIsToPOIs(_ edgePOIs: [EdgePOI]) -> [POI] {
        return edgePOIs.compactMap { edgePOI -> POI? in
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
