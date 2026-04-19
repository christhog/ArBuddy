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

        // Cache jaw joint if available
        if let jawName = capabilities.jawJointName {
            findJawJoint(named: jawName, in: entity)
        }

        // Cache blend shape names
        blendShapeNames = capabilities.blendShapes

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
              let blendShapes = viseme.blendShapes else {
            // Fall back to viseme-to-jaw if no blend shapes in event
            updateVisemeJaw(at: time)
            return
        }

        // TODO: Apply blend shapes directly when model supports it
        // For now, extract jawOpen and use it
        if let jawOpen = blendShapes[ARKitBlendShapes.jawOpen] {
            targetJawOpenness = jawOpen
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

        if modelCapabilities.hasJawJoint, let jawIndex = jawJointIndex {
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

        if let original = originalJawTransform {
            entity.move(to: original, relativeTo: entity.parent, duration: 0.1)
        }

        // Reset any scale modifications
        let baseScale = entity.scale.x
        entity.scale = SIMD3<Float>(repeating: baseScale)
    }
}

// MARK: - Model Inspection Extension

extension LipSyncService {
    /// Inspects a model entity and returns its lip sync capabilities
    nonisolated func inspectModel(_ entity: ModelEntity) async -> ModelCapabilities {
        var blendShapes: [String] = []
        var joints: [String] = []

        // Inspect mesh for blend shapes
        if let model = entity.model {
            // Check if mesh has blend shape data
            // Note: RealityKit's MeshResource doesn't directly expose blend shapes
            // This would require examining the USDZ file structure
            print("[LipSync] Model has \(model.materials.count) materials")
        }

        // Recursively find all joint names in the entity hierarchy
        await collectJointNames(from: entity, into: &joints)

        print("[LipSync] Found joints: \(joints)")

        return ModelCapabilities(blendShapes: blendShapes, skeletonJoints: joints)
    }

    /// Recursively collects entity names that might be joints
    private func collectJointNames(from entity: Entity, into joints: inout [String]) async {
        let name = entity.name
        if !name.isEmpty {
            joints.append(name)
        }

        for child in entity.children {
            await collectJointNames(from: child, into: &joints)
        }
    }
}
