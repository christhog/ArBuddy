//
//  Buddy.swift
//  ARBuddy
//
//  Created by Chris Greve on 19.01.26.
//

import Foundation

struct Buddy: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let description: String?
    let modelUrl: String
    let thumbnailUrl: String?
    let isDefault: Bool
    let sortOrder: Int
    let scale: Float
    let yOffset: Float
    let walkRadius: Float
    let walkSpeed: Float
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, description, scale
        case modelUrl = "model_url"
        case thumbnailUrl = "thumbnail_url"
        case isDefault = "is_default"
        case sortOrder = "sort_order"
        case yOffset = "y_offset"
        case walkRadius = "walk_radius"
        case walkSpeed = "walk_speed"
        case createdAt = "created_at"
    }

    // Supabase Storage base URL
    private static let storageBaseURL = "https://ibhaixdirrejsxalntvx.supabase.co/storage/v1/object/public/buddies/"

    var fullModelUrl: URL? {
        URL(string: Self.storageBaseURL + modelUrl)
    }

    var fullThumbnailUrl: URL? {
        guard let thumbnailUrl else { return nil }
        return URL(string: Self.storageBaseURL + thumbnailUrl)
    }

    /// Returns the local filename for caching
    var localFileName: String {
        // Extract filename from model_url (e.g., "models/jona.usdz" -> "jona.usdz")
        let components = modelUrl.split(separator: "/")
        return String(components.last ?? Substring(modelUrl))
    }
}
