//
//  LipSyncService.swift
//  ARBuddy
//
//  Created by Claude on 15.04.26.
//

import Foundation
import RealityKit
import Combine
import simd
import QuartzCore

// MARK: - Lip Sync Service

/// Manages lip sync animations for 3D buddy models
/// Supports blend shapes, jaw rotation, and amplitude-based fallback
@MainActor
class LipSyncService: ObservableObject {
    static let shared = LipSyncService()

    // MARK: - Published Properties

    @Published private(set) var state: LipSyncState = .idle
    @Published private(set) var currentMode: LipSyncMode = .disabled
    @Published private(set) var modelCapabilities: ModelCapabilities = .none

    // MARK: - Configuration

    var configuration = LipSyncConfiguration.default

    // MARK: - Private Properties

    private var displayLink: CADisplayLink?
    private var buddyEntity: ModelEntity?
    private var jawJointIndex: Int?
    private var originalJawTransform: Transform?

    private var visemeQueue = VisemeQueue()
    private var audioStartTime: Date?
    private var lastVisemeId: Int = 0
    private var currentJawOpenness: Float = 0.0
    private var targetJawOpenness: Float = 0.0

    // Amplitude-based fallback
    private var currentAmplitude: Float = 0.0

    // Blend shapes cache
    private var blendShapeNames: [String] = []
    private var blendShapeTargets: [RealityKitBlendShapeTarget] = []
    private var currentBlendShapes: [String: Float] = [:]
    private var targetBlendShapes: [String: Float] = [:]

    private struct RealityKitBlendShapeTarget {
        let entity: Entity
        let weightSetID: String
        let indexByShapeName: [String: Int]
    }

    // Audio latency compensation: deaktiviert - verursachte Timing-Probleme
    // (subtrahierte Zeit, wodurch Animation vorauslief statt synchron)
    private let audioLatencyOffset: TimeInterval = 0.0

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Configures lip sync for a buddy entity
    /// Call this when the buddy model is loaded/placed
    func configure(for entity: ModelEntity, capabilities: ModelCapabilities) {
        self.buddyEntity = entity
        self.modelCapabilities = capabilities
        self.currentMode = capabilities.recommendedLipSyncMode
        self.blendShapeTargets = collectRealityKitBlendShapeTargets(from: entity)

        // Cache jaw joint if available
        if let jawName = capabilities.jawJointName {
            findJawJoint(named: jawName, in: entity)
        }

        // Cache blend shape names
        blendShapeNames = capabilities.blendShapes
        if !blendShapeTargets.isEmpty {
            currentMode = .blendShapes
            let targetCount = blendShapeTargets.reduce(0) { $0 + $1.indexByShapeName.count }
            print("[LipSync] RealityKit blend shape targets available: \(blendShapeTargets.count) weight set(s), \(targetCount) mapped names")
        }

        print("[LipSync] Configured with mode: \(currentMode.displayName)")
        print("[LipSync] Capabilities: blendShapes=\(capabilities.hasBlendShapes), jawJoint=\(capabilities.hasJawJoint)")
    }

    /// Sets the lip sync mode manually
    func setMode(_ mode: LipSyncMode) {
        guard mode != currentMode else { return }
        currentMode = mode
        print("[LipSync] Mode changed to: \(mode.displayName)")
    }

    /// Starts lip sync animation with viseme data
    /// Called when TTS audio begins playback
    /// - Parameters:
    ///   - visemes: Array of viseme events with timing
    ///   - audioStartTime: The exact time audio playback started (for sync). If nil, uses current time.
    func startAnimation(with visemes: [VisemeEvent], audioStartTime: Date? = nil) {
        guard currentMode != .disabled else { return }
        guard !visemes.isEmpty else {
            print("[LipSync] No visemes provided, using amplitude fallback")
            startAmplitudeMode()
            return
        }

        visemeQueue.reset()
        visemeQueue.enqueue(visemes)

        // Use provided start time for synchronization, or current time if not provided
        self.audioStartTime = audioStartTime ?? Date()
        state = .animating(progress: 0.0)

        startDisplayLink()

        let timeSinceStart = Date().timeIntervalSince(self.audioStartTime!)
        print("[LipSync] Started animation with \(visemes.count) visemes, sync offset: \(String(format: "%.3f", timeSinceStart))s")
    }

    /// Starts amplitude-based lip sync (fallback when no visemes)
    func startAmplitudeMode() {
        guard currentMode != .disabled else { return }

        audioStartTime = Date()
        state = .animating(progress: 0.0)

        startDisplayLink()

        print("[LipSync] Started amplitude-based animation")
    }

    /// Updates audio amplitude for amplitude-based lip sync
    func updateAmplitude(_ amplitude: Float) {
        guard state.isActive else { return }
        currentAmplitude = amplitude
    }

    /// Stops lip sync animation
    func stopAnimation() {
        stopDisplayLink()
        resetJaw()

        visemeQueue.reset()
        audioStartTime = nil
        currentJawOpenness = 0.0
        targetJawOpenness = 0.0
        currentAmplitude = 0.0
        currentBlendShapes.removeAll()
        targetBlendShapes.removeAll()

        state = .finished

        // Brief delay before returning to idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.state = .idle
        }

        print("[LipSync] Animation stopped")
    }

    /// Cleans up resources when buddy is removed
    func cleanup() {
        stopAnimation()
        buddyEntity = nil
        jawJointIndex = nil
        originalJawTransform = nil
        blendShapeTargets.removeAll()
        modelCapabilities = .none
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkUpdate))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkUpdate(_ link: CADisplayLink) {
        guard state.isActive, let startTime = audioStartTime else { return }

        let currentTime = Date().timeIntervalSince(startTime)

        // Update progress
        let duration = max(visemeQueue.duration, 0.1)
        let progress = Float(min(currentTime / duration, 1.0))
        state = .animating(progress: progress)

        // Past the last viseme event → close mouth (end of speech)
        if visemeQueue.hasEvents && visemeQueue.isPastEnd(at: currentTime) {
            targetJawOpenness = 0.0
        } else {
            // Determine target jaw openness based on mode
            switch currentMode {
            case .blendShapes:
                updateBlendShapes(at: currentTime)
            case .visemeToJaw:
                updateVisemeJaw(at: currentTime)
            case .amplitudeBased:
                updateAmplitudeJaw()
            case .disabled:
                break
            }
        }

        // Apply smoothed jaw animation
        applyJawAnimation()
    }

    // MARK: - Animation Updates

    private func updateBlendShapes(at time: TimeInterval) {
        // Compensate for audio hardware latency
        let adjustedTime = max(0, time - audioLatencyOffset)

        guard let viseme = visemeQueue.viseme(at: adjustedTime),
              viseme.blendShapes != nil || !blendShapeTargets.isEmpty else {
            updateVisemeJaw(at: time)
            return
        }

        let rawJaw = VisemeJawMapping.jawOpenness(for: viseme.visemeId)
        let clampedJaw: Float = rawJaw < 0.06 ? 0.0 : rawJaw
        let boostedJaw: Float = min(clampedJaw * 1.5, 1.0)

        if let blendShapes = viseme.blendShapes {
            targetBlendShapes = blendShapes
            targetJawOpenness = blendShapes[ARKitBlendShapes.jawOpen] ?? boostedJaw
        } else {
            var shapes: [String: Float] = [:]
            if clampedJaw > 0 {
                let rawShapes = VisemeBlendShapeMapping.blendShapes(for: viseme.visemeId)
                let auxiliaryGain: Float = 0.7
                for (name, value) in rawShapes where name != "jawOpen" {
                    shapes[name] = min(value * auxiliaryGain, 1.0)
                }
                shapes["jawOpen"] = boostedJaw
            }
            if viseme.visemeId == 21 {
                shapes["mouthClose"] = 0.6
                shapes["mouthPressLeft"] = 0.4
                shapes["mouthPressRight"] = 0.4
            }
            targetBlendShapes = shapes
            targetJawOpenness = boostedJaw
        }
    }

    private func updateVisemeJaw(at time: TimeInterval) {
        // Compensate for audio hardware latency
        let adjustedTime = max(0, time - audioLatencyOffset)

        guard let viseme = visemeQueue.viseme(at: adjustedTime) else {
            targetJawOpenness = 0.0
            return
        }

        if viseme.visemeId != lastVisemeId {
            lastVisemeId = viseme.visemeId
            targetJawOpenness = VisemeJawMapping.jawOpenness(for: viseme.visemeId)
            targetBlendShapes = targetJawOpenness > 0 ? ["jawOpen": targetJawOpenness] : [:]
        }
    }

    private func updateAmplitudeJaw() {
        // Map amplitude (0.0-1.0) to jaw openness
        let threshold = configuration.minAmplitudeThreshold
        if currentAmplitude > threshold {
            targetJawOpenness = min((currentAmplitude - threshold) / (1.0 - threshold), 1.0) * 0.8
        } else {
            targetJawOpenness = 0.0
        }
        targetBlendShapes = targetJawOpenness > 0 ? ["jawOpen": targetJawOpenness] : [:]
    }

    private func applyJawAnimation() {
        // Asymmetric smoothing: fast close (pauses visible), slower open (natural speech feel)
        // Closing: 85% of remaining distance per frame (~3 frames at 60fps)
        // Opening: 40% of remaining distance per frame (~10 frames at 60fps)
        let lerpFactor: Float = targetJawOpenness < currentJawOpenness ? 0.85 : 0.40
        currentJawOpenness = currentJawOpenness + (targetJawOpenness - currentJawOpenness) * lerpFactor

        // Hard silence snap: below threshold → exactly 0 (clean visual silence)
        if currentJawOpenness < 0.02 {
            currentJawOpenness = 0.0
        }

        guard let entity = buddyEntity else { return }

        if applyRealityKitBlendShapes() {
            return
        } else if modelCapabilities.hasJawJoint, let jawIndex = jawJointIndex {
            // Apply jaw rotation
            applyJawRotation(to: entity, jointIndex: jawIndex, openness: currentJawOpenness)
        } else {
            // Simple scale fallback - slightly scale the lower part of the face
            // This is a minimal fallback when no jaw joint is available
            applyScaleFallback(to: entity, openness: currentJawOpenness)
        }
    }

    // MARK: - Jaw Joint Methods

    private func findJawJoint(named name: String, in entity: ModelEntity) {
        // Try to find joint in skeleton
        // RealityKit's joint access is limited, we'll store the name for later use
        print("[LipSync] Looking for jaw joint: \(name)")

        // For now, we'll use transform-based animation on the entity itself
        // Full skeleton joint access requires more complex setup with AnimationResource
        jawJointIndex = 0  // Placeholder - actual implementation depends on model structure
        originalJawTransform = entity.transform
    }

    private func applyJawRotation(to entity: ModelEntity, jointIndex: Int, openness: Float) {
        // Calculate rotation angle based on openness
        let maxAngle = configuration.maxJawAngle
        let angle = openness * maxAngle

        // Rotate around X axis (opening jaw downward)
        // Note: Actual implementation may need adjustment based on model orientation
        guard let original = originalJawTransform else { return }

        var newTransform = original
        let rotationDelta = simd_quatf(angle: angle, axis: SIMD3<Float>(1, 0, 0))
        newTransform.rotation = original.rotation * rotationDelta

        // Apply with smooth transition
        entity.move(to: newTransform, relativeTo: entity.parent, duration: 0.016)
    }

    private func applyScaleFallback(to entity: ModelEntity, openness: Float) {
        // Minimal fallback: slightly adjust Y scale to simulate mouth movement
        // This is very subtle but provides some visual feedback
        let baseScale = entity.scale.x  // Assume uniform base scale
        let scaleOffset = openness * 0.02  // Very subtle 2% max

        // Apply to Y axis only (vertical stretch)
        entity.scale.y = baseScale * (1.0 + scaleOffset)
    }

    private func resetJaw() {
        guard let entity = buddyEntity else { return }

        resetRealityKitBlendShapes()

        if let original = originalJawTransform {
            entity.move(to: original, relativeTo: entity.parent, duration: 0.1)
        }

        // Reset any scale modifications
        let baseScale = entity.scale.x
        entity.scale = SIMD3<Float>(repeating: baseScale)
    }

    @discardableResult
    private func applyRealityKitBlendShapes() -> Bool {
        guard !blendShapeTargets.isEmpty else { return false }

        let shapeNames = Set(
            VisemeBlendShapeMapping.allUsedShapes +
            Array(targetBlendShapes.keys) +
            Array(currentBlendShapes.keys)
        )
        let closeRate: Float = 0.55
        let openRate: Float = 0.45

        for shapeName in shapeNames {
            let target = targetBlendShapes[shapeName] ?? 0.0
            let current = currentBlendShapes[shapeName] ?? 0.0
            let rate = target < current ? closeRate : openRate
            let newValue = current + (target - current) * rate

            if newValue < 0.001 {
                currentBlendShapes[shapeName] = 0.0
            } else {
                currentBlendShapes[shapeName] = newValue
            }
        }

        for target in blendShapeTargets {
            guard var component = target.entity.components[BlendShapeWeightsComponent.self],
                  var data = component.weightSet[target.weightSetID] else {
                continue
            }

            var weights = data.weights
            for (shapeName, value) in currentBlendShapes {
                guard let index = target.indexByShapeName[shapeName],
                      index >= weights.startIndex,
                      index < weights.endIndex else {
                    continue
                }
                weights[index] = value
            }
            data.weights = weights
            component.weightSet.set(data)
            target.entity.components[BlendShapeWeightsComponent.self] = component
        }

        return true
    }

    private func resetRealityKitBlendShapes() {
        guard !blendShapeTargets.isEmpty else { return }

        for target in blendShapeTargets {
            guard var component = target.entity.components[BlendShapeWeightsComponent.self],
                  var data = component.weightSet[target.weightSetID] else {
                continue
            }

            var weights = data.weights
            for index in weights.indices {
                weights[index] = 0
            }
            data.weights = weights
            component.weightSet.set(data)
            target.entity.components[BlendShapeWeightsComponent.self] = component
        }
    }

    private func collectRealityKitBlendShapeTargets(from entity: Entity) -> [RealityKitBlendShapeTarget] {
        var result: [RealityKitBlendShapeTarget] = []

        func visit(_ current: Entity) {
            if let component = current.components[BlendShapeWeightsComponent.self] {
                for data in component.weightSet {
                    let indexMap = makeBlendShapeIndexMap(from: data.weightNames)
                    if !indexMap.isEmpty {
                        result.append(
                            RealityKitBlendShapeTarget(
                                entity: current,
                                weightSetID: data.id,
                                indexByShapeName: indexMap
                            )
                        )
                        print("[LipSync] Found RealityKit blend weight set '\(data.id)' on '\(current.name)' with \(data.weightNames.count) weights")
                    }
                }
            }

            for child in current.children {
                visit(child)
            }
        }

        visit(entity)
        return result
    }

    private func collectRealityKitBlendShapeNames(from entity: Entity) -> [String] {
        var names = Set<String>()

        func visit(_ current: Entity) {
            if let component = current.components[BlendShapeWeightsComponent.self] {
                for data in component.weightSet {
                    names.formUnion(data.weightNames)
                }
            }

            for child in current.children {
                visit(child)
            }
        }

        visit(entity)
        return Array(names).sorted()
    }

    private func makeBlendShapeIndexMap(from weightNames: [String]) -> [String: Int] {
        var result: [String: Int] = [:]

        for (index, name) in weightNames.enumerated() {
            result[name] = index
            let canonical = canonicalBlendShapeName(name)
            if result[canonical] == nil {
                result[canonical] = index
            }
        }

        return result
    }

    private func canonicalBlendShapeName(_ name: String) -> String {
        var result = name
        while result.last?.isNumber == true {
            result.removeLast()
        }
        return result
    }
}

// MARK: - Model Inspection Extension

extension LipSyncService {
    /// Inspects a model entity and returns its lip sync capabilities
    func inspectModel(_ entity: ModelEntity) async -> ModelCapabilities {
        let blendShapes = collectRealityKitBlendShapeNames(from: entity)
        var joints: [String] = []

        // Inspect mesh for blend shapes
        if let model = entity.model {
            print("[LipSync] Model has \(model.materials.count) materials")
        }

        // Recursively find all joint names in the entity hierarchy
        collectJointNames(from: entity, into: &joints)

        if !blendShapes.isEmpty {
            print("[LipSync] Found RealityKit blend shapes: \(blendShapes.prefix(24).joined(separator: ", "))\(blendShapes.count > 24 ? " ..." : "")")
        }
        print("[LipSync] Found joints: \(joints)")

        return ModelCapabilities(blendShapes: blendShapes, skeletonJoints: joints)
    }

    /// Recursively collects entity names that might be joints
    private func collectJointNames(from entity: Entity, into joints: inout [String]) {
        let name = entity.name
        if !name.isEmpty {
            joints.append(name)
        }

        for child in entity.children {
            collectJointNames(from: child, into: &joints)
        }
    }
}
