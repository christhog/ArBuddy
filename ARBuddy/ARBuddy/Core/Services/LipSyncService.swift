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
    private var buddyEntity: Entity?
    private var jawJointIndex: Int?
    private var jawDriveEntity: Entity?
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
    private var lastLoggedRealityKitVisemeId: Int = -1
    private var didLogRealityKitBlendWrite = false
    private var didLogJawFallbackDrive = false
    private var realityKitBlendAnimationControllers: [AnimationPlaybackController] = []
    private let realityKitBlendShapeWeightScale: Float = 1.0
    private let realityKitSampledAnimationLead: TimeInterval = 0.10

    private struct RealityKitBlendShapeTarget {
        let entity: Entity
        let weightSetID: String
        let weightSetIndex: Int
        let weightNames: [String]
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
    func configure(for entity: Entity, capabilities: ModelCapabilities) {
        self.buddyEntity = entity
        self.modelCapabilities = capabilities
        self.currentMode = capabilities.recommendedLipSyncMode
        self.blendShapeTargets = collectRealityKitBlendShapeTargets(from: entity)
        self.didLogRealityKitBlendWrite = false
        self.didLogJawFallbackDrive = false
        self.lastLoggedRealityKitVisemeId = -1

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
        } else if capabilities.hasJawJoint {
            currentMode = .visemeToJaw
            print("[LipSync] No usable RealityKit face blend-shape target found; using jaw/mouth entity fallback")
        } else if currentMode == .blendShapes {
            currentMode = .amplitudeBased
            print("[LipSync] No usable RealityKit face blend-shape target found; using amplitude fallback")
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
    func startAnimation(with visemes: [VisemeEvent],
                        audioStartTime: Date? = nil,
                        audioDuration: TimeInterval? = nil) {
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

        logLipSyncTiming(visemes: visemes, audioDuration: audioDuration)
        if currentMode == .blendShapes, !blendShapeTargets.isEmpty {
            // Body mocap is a RealityKit animation on the same character.
            // Drive lips through component writes so skeletal body animation
            // can keep running instead of competing with a second animation
            // resource on the same bind tree.
            stopRealityKitBlendShapeAnimation()
            startDisplayLink()
        } else {
            startDisplayLink()
        }

        let timeSinceStart = Date().timeIntervalSince(self.audioStartTime!)
        print("[LipSync] Started animation with \(visemes.count) visemes, sync offset: \(String(format: "%.3f", timeSinceStart))s")
    }

    private func logLipSyncTiming(visemes: [VisemeEvent], audioDuration: TimeInterval?) {
        let sortedVisemes = visemes.sorted { $0.audioOffset < $1.audioOffset }
        guard let first = sortedVisemes.first, let last = sortedVisemes.last else { return }

        let firstNonSilent = sortedVisemes.first { $0.visemeId != 0 }
        let lastNonSilent = sortedVisemes.last { $0.visemeId != 0 }
        let nonSilentCount = sortedVisemes.filter { $0.visemeId != 0 }.count
        let visemeDuration = last.audioOffset
        let audioDurationText = audioDuration.map { String(format: "%.3f", $0) } ?? "unknown"
        let tailGap = audioDuration.map { $0 - visemeDuration }
        let tailGapText = tailGap.map { String(format: "%.3f", $0) } ?? "unknown"
        let firstNonSilentText = firstNonSilent.map { String(format: "%.3f", $0.audioOffset) } ?? "none"
        let lastNonSilentText = lastNonSilent.map { String(format: "%.3f", $0.audioOffset) } ?? "none"
        let largestGaps = zip(sortedVisemes, sortedVisemes.dropFirst())
            .map { previous, next in
                (from: previous.audioOffset, to: next.audioOffset, gap: next.audioOffset - previous.audioOffset)
            }
            .filter { $0.gap >= 0.28 }
            .sorted { $0.gap > $1.gap }
            .prefix(6)
            .map { String(format: "%.2f-%.2fs gap=%.2f", $0.from, $0.to, $0.gap) }
            .joined(separator: " | ")

        print("[LipSync/SYNC] audioDuration=\(audioDurationText)s visemeLast=\(String(format: "%.3f", visemeDuration))s tailGap=\(tailGapText)s first=\(String(format: "%.3f", first.audioOffset))s firstNonSilent=\(firstNonSilentText)s lastNonSilent=\(lastNonSilentText)s count=\(sortedVisemes.count) nonSilent=\(nonSilentCount)")
        if !largestGaps.isEmpty {
            print("[LipSync/SYNC] largestVisemeGaps \(largestGaps)")
        }
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
        stopRealityKitBlendShapeAnimation()
        resetJaw()

        visemeQueue.reset()
        audioStartTime = nil
        currentJawOpenness = 0.0
        targetJawOpenness = 0.0
        currentAmplitude = 0.0
        currentBlendShapes.removeAll()
        targetBlendShapes.removeAll()
        lastLoggedRealityKitVisemeId = -1
        didLogRealityKitBlendWrite = false
        didLogJawFallbackDrive = false

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
        jawDriveEntity = nil
        originalJawTransform = nil
        blendShapeTargets.removeAll()
        realityKitBlendAnimationControllers.removeAll()
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
        let boostedJaw: Float = min(clampedJaw * 0.75, 0.65)

        if let blendShapes = viseme.blendShapes {
            targetBlendShapes = blendShapes
            targetJawOpenness = blendShapes[ARKitBlendShapes.jawOpen] ?? boostedJaw
        } else {
            var shapes: [String: Float] = [:]
            if clampedJaw > 0 {
                let rawShapes = VisemeBlendShapeMapping.blendShapes(for: viseme.visemeId)
                let auxiliaryGain: Float = 0.35
                for (name, value) in rawShapes where name != "jawOpen" {
                    shapes[name] = min(value * auxiliaryGain, 1.0)
                }
                shapes["jawOpen"] = boostedJaw
            }
            if viseme.visemeId == 21 {
                shapes["mouthClose"] = 0.35
                shapes["mouthPressLeft"] = 0.2
                shapes["mouthPressRight"] = 0.2
            }
            targetBlendShapes = shapes
            targetJawOpenness = boostedJaw
        }

        if viseme.visemeId != lastLoggedRealityKitVisemeId {
            lastLoggedRealityKitVisemeId = viseme.visemeId
            let names = targetBlendShapes
                .filter { $0.value > 0.01 }
                .sorted { $0.key < $1.key }
                .prefix(4)
                .map { "\($0.key)=\(String(format: "%.2f", $0.value))" }
                .joined(separator: ", ")
            print("[LipSync/RK] Viseme \(viseme.visemeId) target jaw=\(String(format: "%.2f", targetJawOpenness)) shapes=[\(names)]")
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
            print("[LipSync/Jaw] Viseme \(viseme.visemeId) target jaw=\(String(format: "%.2f", targetJawOpenness))")
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

    private func findJawJoint(named name: String, in entity: Entity) {
        print("[LipSync] Looking for jaw joint: \(name)")

        if let target = findEntity(named: name, in: entity) {
            jawDriveEntity = target
            jawJointIndex = 0
            originalJawTransform = target.transform
            let hasModel = target.components[ModelComponent.self] != nil
            print("[LipSync] Using jaw/mouth drive entity: \(target.name) children=\(target.children.count) hasModel=\(hasModel)")
        } else {
            jawDriveEntity = entity
            jawJointIndex = 0
            originalJawTransform = entity.transform
            print("[LipSync] Jaw entity '\(name)' not found; using root transform fallback")
        }
    }

    private func applyJawRotation(to entity: Entity, jointIndex: Int, openness: Float) {
        let targetEntity = jawDriveEntity ?? entity

        // Calculate rotation angle based on openness
        let maxAngle: Float = 0.85
        let angle = openness * maxAngle

        // Rotate around X axis (opening jaw downward)
        // Note: Actual implementation may need adjustment based on model orientation
        guard let original = originalJawTransform else { return }

        var newTransform = original
        let rotationDelta = simd_quatf(angle: angle, axis: SIMD3<Float>(1, 0, 0))
        newTransform.rotation = original.rotation * rotationDelta
        newTransform.translation.y = original.translation.y - (openness * 0.055)
        newTransform.translation.z = original.translation.z + (openness * 0.018)
        newTransform.scale = original.scale * SIMD3<Float>(1.0, 1.0 + openness * 0.25, 1.0)

        if !didLogJawFallbackDrive, openness > 0.05 {
            didLogJawFallbackDrive = true
            print("[LipSync/Jaw] Driving '\(targetEntity.name)' openness=\(String(format: "%.2f", openness)) yDelta=\(String(format: "%.3f", openness * 0.055))")
        }

        targetEntity.transform = newTransform
    }

    private func applyScaleFallback(to entity: Entity, openness: Float) {
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

        if let targetEntity = jawDriveEntity, let original = originalJawTransform {
            targetEntity.move(to: original, relativeTo: targetEntity.parent, duration: 0.1)
        } else if let original = originalJawTransform {
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

        var wroteAnyWeight = false
        var maxWrittenValue: Float = 0

        for target in blendShapeTargets {
            guard var component = target.entity.components[BlendShapeWeightsComponent.self],
                  var data = blendShapeWeightsData(in: component, for: target.weightSetID) else {
                continue
            }

            var weights = data.weights
            for (shapeName, value) in currentBlendShapes {
                guard let index = target.indexByShapeName[shapeName],
                      index >= weights.startIndex,
                      index < weights.endIndex else {
                    continue
                }
                let scaledValue = scaledRealityKitBlendShapeWeight(value)
                weights[index] = scaledValue
                wroteAnyWeight = true
                maxWrittenValue = max(maxWrittenValue, scaledValue)
            }
            data.weights = weights
            setBlendShapeWeightsData(data, in: &component, for: target.weightSetID)
            target.entity.components[BlendShapeWeightsComponent.self] = component
        }

        if !didLogRealityKitBlendWrite, wroteAnyWeight {
            didLogRealityKitBlendWrite = true
            print("[LipSync/RK] Writing RealityKit blend weights to \(blendShapeTargets.count) target(s), max=\(String(format: "%.2f", maxWrittenValue))")
        }

        return true
    }

    private func resetRealityKitBlendShapes() {
        guard !blendShapeTargets.isEmpty else { return }

        for target in blendShapeTargets {
            guard var component = target.entity.components[BlendShapeWeightsComponent.self],
                  var data = blendShapeWeightsData(in: component, for: target.weightSetID) else {
                continue
            }

            var weights = data.weights
            for index in weights.indices {
                weights[index] = 0
            }
            data.weights = weights
            setBlendShapeWeightsData(data, in: &component, for: target.weightSetID)
            target.entity.components[BlendShapeWeightsComponent.self] = component
        }
    }

    private func startRealityKitBlendShapeAnimation(with visemes: [VisemeEvent],
                                                    audioDuration: TimeInterval? = nil) {
        stopRealityKitBlendShapeAnimation()
        guard !blendShapeTargets.isEmpty, !visemes.isEmpty else { return }

        let sortedVisemes = visemes.sorted { $0.audioOffset < $1.audioOffset }
        let frameInterval: TimeInterval = 1.0 / 30.0
        let lead = realityKitSampledAnimationLead
        let lastOffset = sortedVisemes.last?.audioOffset ?? 0
        let targetDuration = audioDuration ?? lastOffset
        let duration = max(targetDuration - lead, frameInterval)
        let frameCount = max(Int(ceil(duration / frameInterval)) + 1, 2)
        print("[LipSync/SYNC] sampledDuration=\(String(format: "%.3f", duration))s lead=\(String(format: "%.3f", lead))s frameCount=\(frameCount) frameInterval=\(String(format: "%.3f", frameInterval))s")

        for target in blendShapeTargets {
            var maxFrameWeight: Float = 0
            let frames = (0..<frameCount).map { frameIndex -> BlendShapeWeights in
                let time = min(lead + TimeInterval(frameIndex) * frameInterval, targetDuration)
                let viseme = viseme(in: sortedVisemes, at: time)
                let weights = blendShapeWeights(for: viseme, target: target)
                maxFrameWeight = max(maxFrameWeight, weights.map { $0 }.max() ?? 0)
                return weights
            }

            let bindTarget = blendShapeBindTarget(for: target)
            let animationDefinition = SampledAnimation<BlendShapeWeights>(
                weightNames: target.weightNames,
                frames: frames,
                name: "LipSync_BlendShapes_\(target.entity.name)",
                tweenMode: .linear,
                frameInterval: Float(frameInterval),
                isAdditive: false,
                bindTarget: bindTarget,
                blendLayer: 100,
                repeatMode: .none,
                fillMode: []
            )

            do {
                let animation = try AnimationResource.generate(with: animationDefinition)
                let controller = target.entity.playAnimation(
                    animation,
                    transitionDuration: 0,
                    blendLayerOffset: 0,
                    separateAnimatedValue: true,
                    startsPaused: false
                )
                realityKitBlendAnimationControllers.append(controller)
                print("[LipSync/RK] Playing sampled blend-shape animation on '\(target.entity.name)' frames=\(frames.count) weights=\(target.weightNames.count) max=\(String(format: "%.2f", maxFrameWeight))")
            } catch {
                print("[LipSync/RK] Failed to create sampled blend-shape animation: \(error.localizedDescription)")
            }
        }
    }

    private func stopRealityKitBlendShapeAnimation() {
        for controller in realityKitBlendAnimationControllers {
            controller.stop()
        }
        realityKitBlendAnimationControllers.removeAll()
    }

    private func viseme(in visemes: [VisemeEvent], at time: TimeInterval) -> VisemeEvent? {
        var result: VisemeEvent?
        for viseme in visemes {
            if viseme.audioOffset <= time {
                result = viseme
            } else {
                break
            }
        }
        return result
    }

    private func blendShapeWeights(for viseme: VisemeEvent?,
                                   target: RealityKitBlendShapeTarget) -> BlendShapeWeights {
        let shapes = targetBlendShapes(for: viseme)
        return blendShapeWeights(from: shapes, target: target)
    }

    private func blendShapeWeights(from shapes: [String: Float],
                                   target: RealityKitBlendShapeTarget) -> BlendShapeWeights {
        var values = Array(repeating: Float(0), count: target.weightNames.count)

        for (shapeName, value) in shapes {
            guard let index = target.indexByShapeName[shapeName],
                  index >= values.startIndex,
                  index < values.endIndex else {
                continue
            }
            values[index] = scaledRealityKitBlendShapeWeight(value)
        }

        return BlendShapeWeights(values)
    }

    private func targetBlendShapes(for viseme: VisemeEvent?) -> [String: Float] {
        guard let viseme else { return [:] }

        let rawJaw = VisemeJawMapping.jawOpenness(for: viseme.visemeId)
        let clampedJaw: Float = rawJaw < 0.06 ? 0.0 : rawJaw
        let boostedJaw: Float = min(clampedJaw * 0.75, 0.65)

        if let blendShapes = viseme.blendShapes {
            return blendShapes
        }

        var shapes: [String: Float] = [:]
        if clampedJaw > 0 {
            let rawShapes = VisemeBlendShapeMapping.blendShapes(for: viseme.visemeId)
            let auxiliaryGain: Float = 0.35
            for (name, value) in rawShapes where name != "jawOpen" {
                shapes[name] = min(value * auxiliaryGain, 1.0)
            }
            shapes["jawOpen"] = boostedJaw
        }
        if viseme.visemeId == 21 {
            shapes["mouthClose"] = 0.35
            shapes["mouthPressLeft"] = 0.2
            shapes["mouthPressRight"] = 0.2
        }
        return shapes
    }

    private func blendShapeBindTarget(for target: RealityKitBlendShapeTarget) -> BindTarget {
        if !target.weightSetID.isEmpty {
            return .blendShapeWeightsWithID(target.weightSetID)
        }
        return .blendShapeWeightsAtIndex(target.weightSetIndex)
    }

    private func blendShapeWeightsData(in component: BlendShapeWeightsComponent,
                                       for weightSetID: String) -> BlendShapeWeightsData? {
        if weightSetID.isEmpty {
            return component.weightSet.default
        }
        return component.weightSet[weightSetID]
    }

    private func setBlendShapeWeightsData(_ data: BlendShapeWeightsData,
                                          in component: inout BlendShapeWeightsComponent,
                                          for weightSetID: String) {
        if weightSetID.isEmpty {
            component.weightSet.default = data
        } else {
            component.weightSet.set(data)
        }
    }

    private func scaledRealityKitBlendShapeWeight(_ value: Float) -> Float {
        value * realityKitBlendShapeWeightScale
    }

    private func collectRealityKitBlendShapeTargets(from entity: Entity) -> [RealityKitBlendShapeTarget] {
        var result: [RealityKitBlendShapeTarget] = []

        func visit(_ current: Entity) {
            if let component = current.components[BlendShapeWeightsComponent.self] {
                for (weightSetIndex, data) in component.weightSet.enumerated() {
                    let indexMap = makeBlendShapeIndexMap(from: data.weightNames)
                    if !indexMap.isEmpty && isUsableRealityKitFaceBlendShapeTarget(entityName: current.name, weightNames: data.weightNames) {
                        result.append(
                            RealityKitBlendShapeTarget(
                                entity: current,
                                weightSetID: data.id,
                                weightSetIndex: weightSetIndex,
                                weightNames: data.weightNames,
                                indexByShapeName: indexMap
                            )
                        )
                        print("[LipSync] Found RealityKit blend weight set '\(data.id)' on '\(current.name)' with \(data.weightNames.count) weights")
                    } else if !indexMap.isEmpty {
                        let sample = data.weightNames.prefix(4).joined(separator: ", ")
                        print("[LipSync] Skipping non-primary RealityKit blend weight set on '\(current.name)' sample=[\(sample)]")
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

    private func isUsableRealityKitFaceBlendShapeTarget(entityName: String, weightNames: [String]) -> Bool {
        let canonicalNames = weightNames.map(canonicalBlendShapeName)
        let hasLipSyncShapes = canonicalNames.contains { name in
            ARKitBlendShapes.lipSyncShapes.contains { lipShape in
                name.caseInsensitiveCompare(lipShape) == .orderedSame
            }
        }
        guard hasLipSyncShapes else { return false }

        let lowerEntityName = entityName.lowercased()
        if lowerEntityName.contains("eyelash") ||
            lowerEntityName.contains("tear") ||
            lowerEntityName.contains("eyebrow") ||
            lowerEntityName.contains("eye") {
            return false
        }

        return true
    }

    private func findEntity(named name: String, in entity: Entity) -> Entity? {
        var bestMatch: Entity?
        var bestScore = Int.min

        func visit(_ current: Entity, depth: Int) {
            if current.name.caseInsensitiveCompare(name) == .orderedSame {
                var score = depth
                if current.components[ModelComponent.self] != nil {
                    score += 1000
                }
                if current.components[BlendShapeWeightsComponent.self] != nil {
                    score += 500
                }
                if score > bestScore {
                    bestScore = score
                    bestMatch = current
                }
            }

            for child in current.children {
                visit(child, depth: depth + 1)
            }
        }

        visit(entity, depth: 0)
        return bestMatch
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
    func inspectModel(_ entity: Entity) async -> ModelCapabilities {
        let blendShapes = collectRealityKitBlendShapeNames(from: entity)
        var joints: [String] = []

        // Inspect mesh for blend shapes
        if let modelEntity = entity as? ModelEntity,
           let model = modelEntity.model {
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
