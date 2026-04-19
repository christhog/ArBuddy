//
//  ModelCapabilities.swift
//  ARBuddy
//
//  Created by Claude on 15.04.26.
//

import Foundation
import RealityKit

// MARK: - Model Capabilities

/// Describes the lip sync capabilities of a 3D model
struct ModelCapabilities: Equatable {
    /// Available blend shapes in the model (for direct ARKit mapping)
    let blendShapes: [String]

    /// Available skeleton joints (for jaw rotation fallback)
    let skeletonJoints: [String]

    /// Whether model has ARKit-compatible blend shapes for lip sync
    var hasBlendShapes: Bool {
        !blendShapes.isEmpty && blendShapes.contains { name in
            ARKitBlendShapes.lipSyncShapes.contains { name.lowercased().contains($0.lowercased()) }
        }
    }

    /// Whether model has a jaw joint for rotation-based lip sync
    var hasJawJoint: Bool {
        skeletonJoints.contains { joint in
            let lower = joint.lowercased()
            return lower.contains("jaw") || lower.contains("chin") || lower.contains("mouth")
        }
    }

    /// The best jaw joint name if available
    var jawJointName: String? {
        // Priority: jaw > chin > mouth
        if let jaw = skeletonJoints.first(where: { $0.lowercased().contains("jaw") }) {
            return jaw
        }
        if let chin = skeletonJoints.first(where: { $0.lowercased().contains("chin") }) {
            return chin
        }
        if let mouth = skeletonJoints.first(where: { $0.lowercased().contains("mouth") }) {
            return mouth
        }
        return nil
    }

    /// Recommended lip sync mode based on model capabilities
    var recommendedLipSyncMode: LipSyncMode {
        if hasBlendShapes {
            return .blendShapes
        } else if hasJawJoint {
            return .visemeToJaw
        } else {
            return .amplitudeBased
        }
    }

    /// Empty capabilities for models without lip sync support
    static let none = ModelCapabilities(blendShapes: [], skeletonJoints: [])
}

// MARK: - Lip Sync Mode

/// Available lip sync animation modes
enum LipSyncMode: String, CaseIterable, Identifiable, Codable {
    case blendShapes = "blendShapes"     // Best: 55 ARKit blend shapes
    case visemeToJaw = "visemeToJaw"     // Good: Jaw rotation from viseme ID
    case amplitudeBased = "amplitudeBased" // Minimal: Audio amplitude → jaw
    case disabled = "disabled"           // No lip sync

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blendShapes:
            return "Blend Shapes (Beste Qualität)"
        case .visemeToJaw:
            return "Kieferbewegung"
        case .amplitudeBased:
            return "Audio-basiert"
        case .disabled:
            return "Deaktiviert"
        }
    }

    var description: String {
        switch self {
        case .blendShapes:
            return "Verwendet 55 ARKit Blend Shapes für realistische Lippenbewegungen"
        case .visemeToJaw:
            return "Öffnet den Kiefer basierend auf Viseme-Daten"
        case .amplitudeBased:
            return "Öffnet den Kiefer basierend auf Audio-Lautstärke"
        case .disabled:
            return "Keine Lippensynchronisation"
        }
    }
}

// MARK: - Lip Sync State

/// Current state of lip sync animation
enum LipSyncState: Equatable {
    case idle                      // Not speaking
    case preparing                 // Loading viseme data
    case animating(progress: Float) // Currently animating (0.0-1.0)
    case finished                  // Animation complete

    var isActive: Bool {
        switch self {
        case .animating: return true
        default: return false
        }
    }
}

// MARK: - Lip Sync Configuration

/// Configuration for lip sync behavior
struct LipSyncConfiguration {
    /// Animation smoothing factor (0.0-1.0, higher = smoother but slower)
    var smoothing: Float = 0.3

    /// Maximum jaw opening angle in radians (for jaw rotation mode)
    var maxJawAngle: Float = 0.3  // ~17 degrees

    /// Minimum jaw opening for amplitude mode
    var minAmplitudeThreshold: Float = 0.1

    /// Speed multiplier for animations
    var animationSpeed: Float = 1.0

    /// Whether to use interpolation between visemes
    var useInterpolation: Bool = true

    /// Default configuration
    static let `default` = LipSyncConfiguration()
}
