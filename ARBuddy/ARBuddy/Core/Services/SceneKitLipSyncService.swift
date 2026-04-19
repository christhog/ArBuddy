//
//  SceneKitLipSyncService.swift
//  ARBuddy
//
//  Created by Claude on 15.04.26.
//

import Foundation
import SceneKit
import QuartzCore
import Combine

// MARK: - SceneKit Lip Sync Service

/// Manages lip sync animations for 3D buddy models rendered with SceneKit
/// Used by BuddyPreviewView which renders SCNNodes instead of RealityKit entities
@MainActor
class SceneKitLipSyncService: ObservableObject {
    static let shared = SceneKitLipSyncService()

    // MARK: - Published Properties

    @Published private(set) var isAnimating = false

    // MARK: - Private Properties

    private weak var buddyNode: SCNNode?
    private weak var jawNode: SCNNode?
    private weak var headNode: SCNNode?

    private var originalJawTransform: SCNMatrix4?
    private var originalJawEulerAngles: SCNVector3?
    private var originalHeadEulerAngles: SCNVector3?

    private var displayLink: CADisplayLink?
    private var visemeQueue = VisemeQueue()
    private var audioStartTime: Date?
    private var lastVisemeId: Int = 0

    private var currentJawOpenness: Float = 0.0
    private var targetJawOpenness: Float = 0.0
    private let smoothing: Float = 0.25  // Faster response for better sync

    // Audio amplitude gate: when the Azure audio is silent (between words / end
    // of utterance) we force the mouth closed, regardless of what the viseme
    // stream claims. Azure emits visemes nearly continuously during speech so
    // without this gate the mouth never stops moving.
    private var audioGateAmplitude: Float = 0.0         // smoothed amplitude
    private let audioGateOpenThreshold: Float = 0.35    // ~-39 dB: clearly voiced
    private let audioGateCloseThreshold: Float = 0.32   // safety net; real viseme offsets handle pause timing
    private var audioGateIsOpen: Bool = false

    // Advanced blend shape tracking
    private var currentBlendShapes: [String: Float] = [:]
    private var targetBlendShapes: [String: Float] = [:]
    private var morpherCache: SCNMorpher?
    private var blendShapeIndices: [String: Int] = [:]        // Cache for primary face morpher
    private var allMorphersCache: [SCNMorpher] = []            // All morphers (Micoo has 6 mesh sections)
    private var morpherBlendShapeIndices: [[String: Int]] = [] // Per-morpher canonical-name caches

    // Audio latency compensation: deaktiviert - verursachte Timing-Probleme
    // (subtrahierte Zeit, wodurch Animation vorauslief statt synchron)
    // Azure's real viseme offsets are already phoneme-accurate. With the SDK
    // path active this stays at 0. If the REST fallback kicks in, viseme timings
    // come from our own phoneme estimator and may need a lead — adjust there.
    private let audioLatencyOffset: TimeInterval = 0.0

    // Animation mode
    private var animationMode: AnimationMode = .none

    // For scale-based animation (works with animated models)
    private var originalScale: SCNVector3?

    enum AnimationMode {
        case morphTargets
        case jawRotation
        case headNod
        case scalePulse  // New: scale-based animation that works with rigged models
        case none
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Configures the lip sync service with a SceneKit buddy node
    /// Call this after loading the USDZ model in BuddyPreviewView
    func configure(buddyNode: SCNNode) {
        // Clear previous caches
        morpherCache = nil
        blendShapeIndices.removeAll()
        allMorphersCache.removeAll()
        morpherBlendShapeIndices.removeAll()
        currentBlendShapes.removeAll()
        targetBlendShapes.removeAll()

        self.buddyNode = buddyNode

        // Debug: Print node hierarchy to understand the rig structure
        print("[SceneKitLipSync] === Node Hierarchy ===")
        printNodeHierarchy(buddyNode, indent: 0)
        print("[SceneKitLipSync] === End Hierarchy ===")

        detectAnimationMode(in: buddyNode)
    }

    /// Debug helper to print node hierarchy
    private func printNodeHierarchy(_ node: SCNNode, indent: Int) {
        let prefix = String(repeating: "  ", count: indent)
        let name = node.name ?? "(unnamed)"
        let hasMorpher = node.morpher != nil ? " [MORPHER]" : ""
        let childCount = node.childNodes.count
        print("\(prefix)- \(name)\(hasMorpher) (\(childCount) children)")

        // Only print first 3 levels to avoid spam
        if indent < 3 {
            for child in node.childNodes {
                printNodeHierarchy(child, indent: indent + 1)
            }
        } else if childCount > 0 {
            print("\(prefix)  ... (\(childCount) more children)")
        }
    }

    /// Starts lip sync animation with viseme data from Azure TTS
    /// - Parameters:
    ///   - visemes: Array of viseme events with timing
    ///   - audioStartTime: The exact time audio playback started (for sync). If nil, uses current time.
    func startAnimation(with visemes: [VisemeEvent], audioStartTime: Date? = nil) {
        guard animationMode != .none else {
            print("[SceneKitLipSync] No animation mode available")
            return
        }

        guard !visemes.isEmpty else {
            print("[SceneKitLipSync] No visemes provided, using amplitude fallback")
            startAmplitudeMode()
            return
        }

        visemeQueue.reset()
        visemeQueue.enqueue(visemes)

        // Use provided start time for synchronization, or current time if not provided
        self.audioStartTime = audioStartTime ?? Date()
        isAnimating = true

        startDisplayLink()

        let timeSinceStart = Date().timeIntervalSince(self.audioStartTime!)
        print("[SceneKitLipSync] Started animation with \(visemes.count) visemes, sync offset: \(String(format: "%.3f", timeSinceStart))s")
    }

    /// Starts amplitude-based lip sync (fallback when no visemes available)
    func startAmplitudeMode() {
        guard animationMode != .none else { return }

        audioStartTime = Date()
        isAnimating = true

        startDisplayLink()

        print("[SceneKitLipSync] Started amplitude-based animation")
    }

    /// Updates audio amplitude for amplitude-based lip sync
    func updateAmplitude(_ amplitude: Float) {
        guard isAnimating else { return }

        // Keep the audio-gate state updated even in viseme mode so displayLinkUpdate
        // can hard-close the mouth during real silence.
        updateAudioGate(rawAmplitude: amplitude)

        // Only drive the jaw directly from amplitude when we have no visemes.
        guard !visemeQueue.hasEvents else { return }

        let threshold: Float = 0.1
        if amplitude > threshold {
            targetJawOpenness = min((amplitude - threshold) / (1.0 - threshold), 1.0) * 0.6
        } else {
            targetJawOpenness = 0.0
        }
    }

    /// Smooths raw audio amplitude and flips the gate with hysteresis.
    private func updateAudioGate(rawAmplitude: Float) {
        // Single-pole low-pass: quick to open, slower to close, so a brief
        // amplitude dip between syllables doesn't snap the mouth shut.
        let attack: Float = 0.6
        let release: Float = 0.65
        let rate = rawAmplitude > audioGateAmplitude ? attack : release
        audioGateAmplitude += (rawAmplitude - audioGateAmplitude) * rate

        if audioGateIsOpen {
            if audioGateAmplitude < audioGateCloseThreshold {
                audioGateIsOpen = false
            }
        } else {
            if audioGateAmplitude > audioGateOpenThreshold {
                audioGateIsOpen = true
            }
        }
    }

    /// Stops lip sync animation and resets to idle pose
    func stopAnimation() {
        stopDisplayLink()
        resetToIdle()

        visemeQueue.reset()
        audioStartTime = nil
        currentJawOpenness = 0.0
        targetJawOpenness = 0.0
        lastVisemeId = 0
        audioGateAmplitude = 0.0
        audioGateIsOpen = false
        isAnimating = false

        print("[SceneKitLipSync] Animation stopped")
    }

    /// Cleans up resources when buddy is removed
    func cleanup() {
        stopAnimation()
        buddyNode = nil
        jawNode = nil
        headNode = nil
        originalJawTransform = nil
        originalJawEulerAngles = nil
        originalHeadEulerAngles = nil
        originalScale = nil
        animationMode = .none

        // Clear caches
        morpherCache = nil
        blendShapeIndices.removeAll()
        allMorphersCache.removeAll()
        morpherBlendShapeIndices.removeAll()
        currentBlendShapes.removeAll()
        targetBlendShapes.removeAll()
    }

    // MARK: - Animation Mode Detection

    private func detectAnimationMode(in node: SCNNode) {
        // Check for morph targets first (best quality)
        if let morpher = findMorpher(in: node) {
            animationMode = .morphTargets
            print("[SceneKitLipSync] Using morph targets")
            printAvailableBlendShapes(morpher)
            return
        }

        // Check for jaw bone
        if let jaw = findJawNode(in: node) {
            // Check if it's an animated skeleton bone (transforms will be overwritten)
            if !isAnimatedSkeletonBone(jaw) {
                jawNode = jaw
                originalJawTransform = jaw.transform
                originalJawEulerAngles = jaw.eulerAngles
                animationMode = .jawRotation
                print("[SceneKitLipSync] Using jaw rotation: \(jaw.name ?? "unnamed")")
                return
            }
            // Skeleton bone found but will be overwritten by animation
            print("[SceneKitLipSync] Jaw is skeleton bone, skipping...")
        }

        // Check for head node as fallback
        if let head = findHeadNode(in: node) {
            // Check if it's an animated skeleton bone (transforms will be overwritten)
            if !isAnimatedSkeletonBone(head) {
                headNode = head
                originalHeadEulerAngles = head.eulerAngles
                animationMode = .headNod
                print("[SceneKitLipSync] Using head nod fallback: \(head.name ?? "unnamed")")
                return
            }
            // Skeleton bone found but will be overwritten by animation
            print("[SceneKitLipSync] Head is skeleton bone, skipping...")
        }

        // Fallback: Scale pulse on container (always works)
        // This is skeleton-safe because scale is not affected by skeletal animations
        originalScale = node.scale
        animationMode = .scalePulse
        print("[SceneKitLipSync] Using scale pulse (skeleton-safe)")
        print("[SceneKitLipSync] Original scale: \(node.scale)")
    }

    /// Checks if a node is part of an animated skeleton
    /// Skeleton bones have their transforms overwritten every frame by the skeletal animation
    private func isAnimatedSkeletonBone(_ node: SCNNode) -> Bool {
        let name = node.name?.lowercased() ?? ""

        // Common skeleton prefixes from rigging tools
        let skeletonPrefixes = [
            "mixamorig_",   // Mixamo
            "bip01",        // 3ds Max Biped
            "bone_",        // Generic
            "armature",     // Blender
            "skeleton",     // Generic
            "rig_"          // Generic
        ]

        for prefix in skeletonPrefixes {
            if name.hasPrefix(prefix) || name.contains(":\(prefix)") {
                return true
            }
        }

        // Check if node has animation players (actively animated)
        return !node.animationKeys.isEmpty
    }

    /// Returns the current animation mode for debugging
    var currentAnimationMode: AnimationMode {
        return animationMode
    }

    /// Debug helper to list all available blend shapes in a morpher
    /// This helps identify the correct names to use for lip sync
    private func printAvailableBlendShapes(_ morpher: SCNMorpher) {
        print("[SceneKitLipSync] === Available Blend Shapes ===")
        print("[SceneKitLipSync] Total targets: \(morpher.targets.count)")

        for (index, target) in morpher.targets.enumerated() {
            let name = target.name ?? "(unnamed)"
            print("[SceneKitLipSync]   [\(index)] \(name)")
        }

        // Check if any jaw-related shape was found
        let jawShapeNames = [
            "jawOpen", "JawOpen", "jaw_open",
            "mouth_open", "MouthOpen", "mouthOpen", "Mouth_Open",
            "Jaw_Open", "JAWOPEN", "MOUTH_OPEN",
            "viseme_O", "viseme_aa", "viseme_EE",
            "A", "Ah", "Open", "open",
            "Fcl_MTH_A", "MTH_A",
            "PHM_A", "eCTRLMouthOpen",
            "mouth", "Mouth", "jaw", "Jaw"
        ]

        var foundJawShape: String? = nil
        for target in morpher.targets {
            if let name = target.name, jawShapeNames.contains(name) {
                foundJawShape = name
                break
            }
        }

        if let jawShape = foundJawShape {
            print("[SceneKitLipSync] ✅ Found jaw shape: '\(jawShape)'")
        } else {
            print("[SceneKitLipSync] ⚠️ No recognized jaw shape found!")
            print("[SceneKitLipSync] Add the correct name to jawShapeNames in applyMorphTargets()")
        }

        print("[SceneKitLipSync] === End Blend Shapes ===")
    }

    // MARK: - Node Finding

    /// Recursively collects every SCNMorpher found in the node hierarchy.
    private func collectAllMorphers(from node: SCNNode, into result: inout [SCNMorpher]) {
        if let morpher = node.morpher, morpher.targets.count > 0 {
            result.append(morpher)
        }
        for child in node.childNodes {
            collectAllMorphers(from: child, into: &result)
        }
    }

    /// Finds the best face morpher in the node hierarchy and populates allMorphersCache.
    /// For models like Micoo (Blender UsdSkel export) there is one morpher per mesh section.
    /// We prefer the morpher whose targets include an exact "jawOpen" name (= face mesh, no suffix).
    private func findMorpher(in node: SCNNode) -> SCNMorpher? {
        allMorphersCache.removeAll()
        collectAllMorphers(from: node, into: &allMorphersCache)

        guard !allMorphersCache.isEmpty else { return nil }

        // Best case: morpher with exact "jawOpen" = the face mesh (Micoo / Blender ARKit export)
        if let faceMorpher = allMorphersCache.first(where: { morpher in
            morpher.targets.contains { $0.name == "jawOpen" }
        }) {
            print("[SceneKitLipSync] Found face morpher with exact jawOpen (\(allMorphersCache.count) morpher(s) total)")
            return faceMorpher
        }

        // Fallback: any morpher with a jawOpen-prefixed target (numbered variants)
        if let jawMorpher = allMorphersCache.first(where: { morpher in
            morpher.targets.contains { $0.name?.hasPrefix("jawOpen") == true }
        }) {
            print("[SceneKitLipSync] Found jaw morpher with jawOpen prefix (\(allMorphersCache.count) morpher(s) total)")
            return jawMorpher
        }

        print("[SceneKitLipSync] Using first available morpher (\(allMorphersCache.count) morpher(s) total)")
        return allMorphersCache.first
    }

    private func findJawNode(in node: SCNNode) -> SCNNode? {
        let jawKeywords = ["jaw", "chin", "mandible", "mouth", "kiefer", "mund"]

        return findNode(in: node, matchingKeywords: jawKeywords)
    }

    private func findHeadNode(in node: SCNNode) -> SCNNode? {
        let headKeywords = ["head", "kopf", "skull", "face", "gesicht"]

        return findNode(in: node, matchingKeywords: headKeywords)
    }

    private func findNode(in node: SCNNode, matchingKeywords keywords: [String]) -> SCNNode? {
        // Check children recursively
        for child in node.childNodes {
            let name = child.name?.lowercased() ?? ""
            for keyword in keywords {
                if name.contains(keyword) {
                    return child
                }
            }

            // Recurse into children
            if let found = findNode(in: child, matchingKeywords: keywords) {
                return found
            }
        }

        return nil
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

    // Debug: Track last logged time to avoid spam
    private static var lastDebugLogTime: TimeInterval = 0

    @objc private func displayLinkUpdate(_ link: CADisplayLink) {
        guard isAnimating, let startTime = audioStartTime else { return }

        let currentTime = Date().timeIntervalSince(startTime)

        // Update target jaw openness based on visemes or amplitude
        if visemeQueue.hasEvents {
            // Past the last viseme event → close mouth (end of speech)
            if visemeQueue.isPastEnd(at: currentTime) {
                targetJawOpenness = 0.0
                targetBlendShapes = [:]
            } else {
                updateVisemeJaw(at: currentTime)
            }

            // Audio amplitude gate: if the actual audio is silent, force the
            // mouth closed. This is what makes pauses between words visible —
            // Azure's viseme stream alone never goes quiet during speech.
            if !audioGateIsOpen {
                targetJawOpenness = 0.0
                targetBlendShapes = [:]
            }

            // Debug logging every 0.5s to track sync
            if currentTime - SceneKitLipSyncService.lastDebugLogTime >= 0.5 {
                SceneKitLipSyncService.lastDebugLogTime = currentTime
                print(String(format: "[SceneKitLipSync] t=%.2fs viseme=%d jaw=%.2f gate=%@ gateAmp=%.2f",
                              currentTime, lastVisemeId, targetJawOpenness,
                              audioGateIsOpen ? "OPEN" : "CLOSED", audioGateAmplitude))
            }
        }
        // Otherwise use amplitude mode with simulated values

        // Apply smoothed animation
        applyAnimation()
    }

    // MARK: - Animation Updates

    private func updateVisemeJaw(at time: TimeInterval) {
        // Compensate for audio hardware latency - delay lip sync to match audio
        let adjustedTime = max(0, time - audioLatencyOffset)

        guard let viseme = visemeQueue.viseme(at: adjustedTime) else {
            targetJawOpenness = 0.0
            targetBlendShapes = [:]
            return
        }

        if viseme.visemeId != lastVisemeId {
            let oldViseme = lastVisemeId
            lastVisemeId = viseme.visemeId
            let rawJaw = VisemeJawMapping.jawOpenness(for: viseme.visemeId)

            let clampedJaw: Float = rawJaw < 0.06 ? 0.0 : rawJaw
            // Visual gain on the jaw so open positions read clearly on Micoo —
            // the raw mapping tops out at 0.6 which looks too subtle.
            let boostedJaw: Float = min(clampedJaw * 1.5, 1.0)
            targetJawOpenness = boostedJaw

            // Full multi-shape mapping (funnel/pucker/smile/stretch/…) for richer
            // mouth shapes. Non-jaw shapes are damped so they support the jaw
            // motion instead of fighting it, and are zeroed entirely on consonant
            // visemes that we treat as silence (rawJaw < 0.15) to avoid jitter.
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
                // p/b/m: force a visible lip closure even though jaw is 0
                shapes["mouthClose"] = 0.6
                shapes["mouthPressLeft"] = 0.4
                shapes["mouthPressRight"] = 0.4
            }
            targetBlendShapes = shapes

            // Debug: Log viseme transitions
            print("[SceneKitLipSync] Viseme change: \(oldViseme)→\(viseme.visemeId) at t=\(String(format: "%.3f", time))s (offset=\(String(format: "%.3f", viseme.audioOffset))s) jaw=\(String(format: "%.2f", targetJawOpenness))")
            return
        }

        // Same viseme held longer than a typical phoneme duration → gap/pause
        // between phonemes or words. Fall back to neutral so the mouth actually
        // closes during silence (Azure doesn't emit explicit silence visemes).
        let phonemeHoldWindow: TimeInterval = 0.09
        if adjustedTime - viseme.audioOffset > phonemeHoldWindow {
            targetJawOpenness = 0.0
            targetBlendShapes = [:]
        }
    }

    private func applyAnimation() {
        // Asymmetric smoothing: fast close (pauses visible), slower open (natural speech feel)
        // Closing: 85% of remaining distance per frame (~3 frames to close at 60fps)
        // Opening: 40% of remaining distance per frame (~10 frames to fully open)
        let lerpFactor: Float = targetJawOpenness < currentJawOpenness ? 0.85 : 0.40
        currentJawOpenness = currentJawOpenness + (targetJawOpenness - currentJawOpenness) * lerpFactor

        // Hard silence snap: below threshold → exactly 0 (clean visual silence)
        if currentJawOpenness < 0.02 {
            currentJawOpenness = 0.0
        }

        switch animationMode {
        case .morphTargets:
            applyAdvancedMorphTargets()
        case .jawRotation:
            applyJawRotation(openness: currentJawOpenness)
        case .headNod:
            applyHeadNod(openness: currentJawOpenness)
        case .scalePulse:
            applyScalePulse(openness: currentJawOpenness)
        case .none:
            break
        }
    }

    // MARK: - Animation Application

    /// Applies advanced morph target animation using multiple blend shapes.
    /// Applies weights to ALL morpher sections so hair, clothes, etc. animate along with the face.
    private func applyAdvancedMorphTargets() {
        guard let buddy = buddyNode else { return }

        // Initialize morpher caches on first call
        if morpherCache == nil {
            morpherCache = findMorpher(in: buddy)
            buildBlendShapeIndexCache()
        }

        guard !allMorphersCache.isEmpty else { return }

        // Asymmetric lerp factors: close faster than we open, so pauses actually
        // read as closed mouths instead of lingering half-open shapes.
        let closeRate: Float = 0.28
        let openRate: Float = 0.30

        for shapeName in VisemeBlendShapeMapping.allUsedShapes {
            let target = targetBlendShapes[shapeName] ?? 0.0
            let current = currentBlendShapes[shapeName] ?? 0.0
            let rate = target < current ? closeRate : openRate
            let newValue = current + (target - current) * rate

            if abs(newValue - current) > 0.001 || newValue > 0.001 {
                currentBlendShapes[shapeName] = newValue

                // Apply to every mesh section (face + hair + clothes + … for Micoo)
                for (morpherIdx, morpher) in allMorphersCache.enumerated() {
                    guard morpherIdx < morpherBlendShapeIndices.count else { continue }
                    if let index = morpherBlendShapeIndices[morpherIdx][shapeName] {
                        morpher.setWeight(CGFloat(newValue), forTargetAt: index)
                    }
                }
            }
        }
    }

    /// Builds per-morpher index caches with canonical (suffix-stripped) name lookup.
    /// Micoo exports numbered variants per mesh section (jawOpen2…jawOpen6 for hair/clothes/etc.).
    /// Stripping the trailing digits maps them to the same canonical ARKit name (jawOpen).
    private func buildBlendShapeIndexCache() {
        morpherBlendShapeIndices.removeAll()
        blendShapeIndices.removeAll()

        for morpher in allMorphersCache {
            var indexMap: [String: Int] = [:]
            for (index, target) in morpher.targets.enumerated() {
                guard let name = target.name else { continue }
                indexMap[name] = index
                // Map canonical name (strip trailing digits) → same index, don't overwrite exact match
                let canonical = name.strippingTrailingDigits()
                if canonical != name && indexMap[canonical] == nil {
                    indexMap[canonical] = index
                }
            }
            morpherBlendShapeIndices.append(indexMap)
        }

        // Keep blendShapeIndices pointing to the face morpher (morpherCache) for compatibility
        if let faceIdx = allMorphersCache.firstIndex(where: { $0 === morpherCache }) {
            blendShapeIndices = morpherBlendShapeIndices[faceIdx]
        } else if !morpherBlendShapeIndices.isEmpty {
            blendShapeIndices = morpherBlendShapeIndices[0]
        }

        print("[SceneKitLipSync] Cached blend shapes across \(allMorphersCache.count) morpher(s), \(blendShapeIndices.count) unique keys in face morpher")
    }

    /// Legacy simple morph target animation (fallback)
    private func applyMorphTargets(openness: Float) {
        guard let buddy = buddyNode,
              let morpher = findMorpher(in: buddy) else { return }

        // Try common blend shape names for jaw
        let jawShapeNames = ["jawOpen", "JawOpen", "jaw_open", "mouthOpen"]

        for name in jawShapeNames {
            if let index = blendShapeIndices[name] ?? morpher.targets.firstIndex(where: { $0.name == name }) {
                morpher.setWeight(CGFloat(openness), forTargetAt: index)
                return
            }
        }
    }

    /// Applies jaw rotation animation (good quality)
    private func applyJawRotation(openness: Float) {
        guard let jaw = jawNode,
              let original = originalJawEulerAngles else { return }

        // Rotate jaw around X axis (opening downward)
        // Max angle ~17 degrees (0.3 radians)
        let maxAngle: Float = 0.3
        let angle = openness * maxAngle

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.016 // ~60fps
        SCNTransaction.disableActions = true

        jaw.eulerAngles = SCNVector3(
            original.x + angle,
            original.y,
            original.z
        )

        SCNTransaction.commit()
    }

    /// Applies subtle head nod animation (minimal fallback)
    private func applyHeadNod(openness: Float) {
        guard let head = headNode,
              let original = originalHeadEulerAngles else {
            print("[SceneKitLipSync] applyHeadNod: No head node or original angles")
            return
        }

        // More visible nodding motion for testing - increase if not visible
        let maxAngle: Float = 0.15 // ~8.5 degrees - more visible for testing
        let angle = openness * maxAngle

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.016
        SCNTransaction.disableActions = true

        head.eulerAngles = SCNVector3(
            original.x + angle,
            original.y,
            original.z
        )

        SCNTransaction.commit()
    }

    /// Applies scale pulse animation - works with ALL models including rigged ones
    /// This is the most reliable fallback as scale is not affected by skeletal animations
    private func applyScalePulse(openness: Float) {
        guard let buddy = buddyNode,
              let original = originalScale else {
            return
        }

        // Scale change: 0-6% increase when speaking (doubled for better visibility)
        // Primary effect on Y axis (vertical "bounce")
        let scaleFactorY: Float = 1.0 + (openness * 0.06)
        // Slight X/Z compression to maintain volume
        let scaleFactorXZ: Float = 1.0 - (openness * 0.02)

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.016
        SCNTransaction.disableActions = true

        buddy.scale = SCNVector3(
            original.x * scaleFactorXZ,
            original.y * scaleFactorY,
            original.z * scaleFactorXZ
        )

        SCNTransaction.commit()
    }

    // MARK: - Reset

    private func resetToIdle() {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.15

        // Clear blend shape tracking
        currentBlendShapes.removeAll()
        targetBlendShapes.removeAll()

        switch animationMode {
        case .morphTargets:
            // Reset all mesh sections
            for morpher in allMorphersCache {
                for index in 0..<morpher.targets.count {
                    morpher.setWeight(0, forTargetAt: index)
                }
            }

        case .jawRotation:
            if let jaw = jawNode,
               let original = originalJawEulerAngles {
                jaw.eulerAngles = original
            }

        case .headNod:
            if let head = headNode,
               let original = originalHeadEulerAngles {
                head.eulerAngles = original
            }

        case .scalePulse:
            if let buddy = buddyNode,
               let original = originalScale {
                buddy.scale = original
            }

        case .none:
            break
        }

        SCNTransaction.commit()
    }
}

// MARK: - String Helper

private extension String {
    /// Returns the string with any trailing numeric characters removed.
    /// e.g. "jawOpen2" → "jawOpen", "mouthClose6" → "mouthClose", "jawOpen" → "jawOpen"
    func strippingTrailingDigits() -> String {
        var result = self
        while result.last?.isNumber == true {
            result.removeLast()
        }
        return result
    }
}
