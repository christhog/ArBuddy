//
//  BuddyAssetService.swift
//  ARBuddy
//
//  Created by Chris Greve on 19.01.26.
//

import Foundation
import RealityKit

// MARK: - Model Inspection Result

/// Result of inspecting a USDZ model for lip sync capabilities
struct ModelInspectionResult {
    let entityHierarchy: [String]
    let jointNames: [String]
    let meshInfo: [String]
    let capabilities: ModelCapabilities

    var description: String {
        var desc = "=== Model Inspection Result ===\n"
        desc += "Entity Hierarchy:\n"
        for name in entityHierarchy {
            desc += "  - \(name)\n"
        }
        desc += "\nJoint/Bone Names:\n"
        for joint in jointNames {
            desc += "  - \(joint)\n"
        }
        desc += "\nMesh Info:\n"
        for info in meshInfo {
            desc += "  - \(info)\n"
        }
        desc += "\nCapabilities:\n"
        desc += "  - Has Blend Shapes: \(capabilities.hasBlendShapes)\n"
        desc += "  - Has Jaw Joint: \(capabilities.hasJawJoint)\n"
        desc += "  - Jaw Joint Name: \(capabilities.jawJointName ?? "none")\n"
        desc += "  - Recommended Mode: \(capabilities.recommendedLipSyncMode.displayName)\n"
        desc += "================================"
        return desc
    }
}

actor BuddyAssetService {
    static let shared = BuddyAssetService()

    private let cacheDirectory: URL
    private var downloadTasks: [UUID: Task<URL, Error>] = [:]

    private init() {
        // Setup cache directory
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesURL.appendingPathComponent("BuddyModels", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Cache Management

    /// Returns the local cache URL for a buddy model
    func localModelURL(for buddy: Buddy) -> URL {
        cacheDirectory.appendingPathComponent(buddy.localFileName)
    }

    /// Checks if the model is already cached locally or bundled
    func isModelCached(for buddy: Buddy) -> Bool {
        let localURL = localModelURL(for: buddy)
        if FileManager.default.fileExists(atPath: localURL.path) {
            return true
        }
        // Also check if bundled
        return bundledModelURL(for: buddy) != nil
    }

    /// Returns the bundled URL for a buddy model if available
    private func bundledModelURL(for buddy: Buddy) -> URL? {
        let bundledOptions: [(name: String, ext: String)] = [
            (buddy.name, "usdz"),
            (buddy.name.lowercased(), "usdz"),
            (buddy.name, "usdc"),
            (buddy.name.lowercased(), "usdc")
        ]

        for option in bundledOptions {
            if let bundledURL = Bundle.main.url(forResource: option.name, withExtension: option.ext) {
                return bundledURL
            }
        }
        return nil
    }

    /// Ensures the model is downloaded and cached, returns the local URL
    func ensureModelCached(for buddy: Buddy) async throws -> URL {
        let localURL = localModelURL(for: buddy)

        // Already cached
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }

        // Check for bundled model (local development fallback)
        if let bundledURL = bundledModelURL(for: buddy) {
            print("Using bundled model for \(buddy.name): \(bundledURL.lastPathComponent)")
            return bundledURL
        }

        // Check if download is already in progress
        if let existingTask = downloadTasks[buddy.id] {
            return try await existingTask.value
        }

        // Start download
        let task = Task<URL, Error> {
            guard let remoteURL = buddy.fullModelUrl else {
                throw BuddyAssetError.invalidURL
            }

            print("Downloading buddy model: \(buddy.name) from \(remoteURL)")

            let (tempURL, response) = try await URLSession.shared.download(from: remoteURL)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw BuddyAssetError.downloadFailed(statusCode: nil, url: remoteURL)
            }

            guard httpResponse.statusCode == 200 else {
                print("Download failed with status \(httpResponse.statusCode) for URL: \(remoteURL)")
                throw BuddyAssetError.downloadFailed(statusCode: httpResponse.statusCode, url: remoteURL)
            }

            // Move to cache directory
            let destination = localModelURL(for: buddy)

            // Remove existing file if any
            try? FileManager.default.removeItem(at: destination)

            try FileManager.default.moveItem(at: tempURL, to: destination)

            print("Buddy model cached: \(destination.path)")
            return destination
        }

        downloadTasks[buddy.id] = task

        do {
            let result = try await task.value
            downloadTasks[buddy.id] = nil
            return result
        } catch {
            downloadTasks[buddy.id] = nil
            throw error
        }
    }

    /// Loads the RealityKit ModelEntity for a buddy
    func loadModelEntity(for buddy: Buddy) async throws -> ModelEntity {
        // Try local cache first
        let localURL = localModelURL(for: buddy)

        if FileManager.default.fileExists(atPath: localURL.path) {
            return try await loadEntity(from: localURL, buddy: buddy)
        }

        // Try bundled fallback
        if let bundledURL = bundledModelURL(for: buddy) {
            print("Using bundled \(bundledURL.lastPathComponent) model")
            return try await loadEntity(from: bundledURL, buddy: buddy)
        }

        // For default buddy, also try legacy "Untitled" names
        if buddy.isDefault {
            let legacyOptions: [(name: String, ext: String)] = [
                ("Untitled", "usdc"),
                ("Untitled", "usdz")
            ]

            for option in legacyOptions {
                if let bundledURL = Bundle.main.url(forResource: option.name, withExtension: option.ext) {
                    print("Using bundled \(option.name).\(option.ext) model")
                    return try await loadEntity(from: bundledURL, buddy: buddy)
                }
            }
        }

        // Download and cache
        let cachedURL = try await ensureModelCached(for: buddy)
        return try await loadEntity(from: cachedURL, buddy: buddy)
    }

    private func loadEntity(from url: URL, buddy: Buddy) async throws -> ModelEntity {
        let entity = try await ModelEntity(contentsOf: url)

        // Apply buddy-specific scale
        entity.scale = SIMD3<Float>(repeating: buddy.scale)

        // Apply Y offset
        entity.position.y = buddy.yOffset

        return entity
    }

    /// Clears all cached models
    func clearCache() throws {
        let contents = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
        for fileURL in contents {
            try FileManager.default.removeItem(at: fileURL)
        }
        print("Buddy model cache cleared")
    }

    /// Returns the size of cached models in bytes
    func cacheSize() -> Int64 {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        var totalSize: Int64 = 0
        for fileURL in contents {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(size)
            }
        }
        return totalSize
    }

    // MARK: - Model Inspection for Lip Sync

    /// Inspects a buddy model to determine its lip sync capabilities
    /// Use this to check if a model has blend shapes or jaw bones
    func inspectModelCapabilities(for buddy: Buddy) async throws -> ModelInspectionResult {
        let entity = try await loadModelEntity(for: buddy)
        return inspectEntity(entity)
    }

    /// Inspects a ModelEntity for lip sync capabilities
    func inspectEntity(_ entity: ModelEntity) -> ModelInspectionResult {
        var hierarchy: [String] = []
        var joints: [String] = []
        var meshInfo: [String] = []
        var blendShapes: [String] = []

        // Collect entity hierarchy
        collectEntityHierarchy(entity, indent: 0, into: &hierarchy)

        // Look for joint/bone names in the hierarchy
        collectJointNames(entity, into: &joints)

        // Inspect mesh
        if let model = entity.model {
            meshInfo.append("Materials: \(model.materials.count)")

            // Check mesh resource for blend shape info
            // Note: RealityKit doesn't directly expose blend shapes,
            // but we can infer from entity names and structure
            let meshBounds = model.mesh.bounds
            meshInfo.append("Bounds: \(meshBounds)")
        }

        // Determine capabilities
        let capabilities = ModelCapabilities(
            blendShapes: blendShapes,
            skeletonJoints: joints
        )

        return ModelInspectionResult(
            entityHierarchy: hierarchy,
            jointNames: joints,
            meshInfo: meshInfo,
            capabilities: capabilities
        )
    }

    /// Recursively collects entity hierarchy with names
    private func collectEntityHierarchy(_ entity: Entity, indent: Int, into result: inout [String]) {
        let prefix = String(repeating: "  ", count: indent)
        let typeName = String(describing: type(of: entity))
        let name = entity.name.isEmpty ? "(unnamed)" : entity.name
        result.append("\(prefix)\(name) [\(typeName)]")

        for child in entity.children {
            collectEntityHierarchy(child, indent: indent + 1, into: &result)
        }
    }

    /// Collects potential joint/bone names from entity hierarchy
    private func collectJointNames(_ entity: Entity, into result: inout [String]) {
        // Check if this entity's name suggests it's a bone/joint
        let name = entity.name.lowercased()
        let boneKeywords = ["bone", "joint", "skeleton", "armature",
                           "jaw", "chin", "mouth", "lip", "tongue",
                           "head", "neck", "face"]

        if !entity.name.isEmpty {
            // Add if it contains bone keywords or follows common naming patterns
            if boneKeywords.contains(where: { name.contains($0) }) ||
               name.hasPrefix("bip") ||  // Biped naming
               name.hasPrefix("def_") || // Deformation bone
               name.contains("_jnt") ||  // Joint suffix
               name.contains("_bn") {    // Bone suffix
                result.append(entity.name)
            }
        }

        // Recurse into children
        for child in entity.children {
            collectJointNames(child, into: &result)
        }
    }

    /// Inspects a bundled USDZ file directly
    func inspectBundledModel(named name: String, extension ext: String = "usdz") async throws -> ModelInspectionResult {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            throw BuddyAssetError.loadFailed
        }

        let entity = try await ModelEntity(contentsOf: url)
        return inspectEntity(entity)
    }
}

// MARK: - Errors

enum BuddyAssetError: LocalizedError {
    case invalidURL
    case downloadFailed(statusCode: Int?, url: URL)
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Ungültige Model-URL"
        case .downloadFailed(let statusCode, let url):
            if let statusCode {
                switch statusCode {
                case 404:
                    return "Model nicht gefunden (404). Prüfe ob die Datei im Storage existiert: \(url.lastPathComponent)"
                case 403:
                    return "Zugriff verweigert (403). Der Storage-Bucket ist möglicherweise nicht public."
                default:
                    return "Download fehlgeschlagen (HTTP \(statusCode))"
                }
            }
            return "Download des Models fehlgeschlagen"
        case .loadFailed:
            return "Model konnte nicht geladen werden"
        }
    }
}
