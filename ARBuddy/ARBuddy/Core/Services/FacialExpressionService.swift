//
//  FacialExpressionService.swift
//  ARBuddy
//
//  Drives eye/brow/cheek blendshapes on the buddy mesh: idle blinking and
//  micro-saccades, held emotion presets (happy/sad/angry/…), and scripted
//  animations (eye roll). Writes directly to the mesh's SCNMorphers on its own
//  CADisplayLink so it works independently of the lip-sync service, which owns
//  the mouth shapes during speech.
//

import Foundation
import SceneKit
import QuartzCore

@MainActor
final class FacialExpressionService {
    static let shared = FacialExpressionService()

    // MARK: - Public Types

    enum Expression: String, CaseIterable {
        case neutral, happy, sad, angry, surprised, thinking, skeptical
        case laughter, fear, disgust, melancholy, wonder

        /// Parses the emotion name Claude emits in `[emotion:xxx]` markers.
        /// Unknown names fall back to `nil` so the caller can skip them.
        static func fromMarker(_ raw: String) -> Expression? {
            Expression(rawValue: raw.lowercased())
        }
    }

    enum Brow {
        case left, right, both
    }

    // MARK: - State

    private weak var buddyNode: SCNNode?
    private var morphers: [SCNMorpher] = []
    private var indexCache: [[String: Int]] = []
    private var lastWrittenKeys: Set<String> = []

    private var displayLink: CADisplayLink?

    private var idleRunning = false
    private var nextBlinkAt: CFTimeInterval = 0
    private var nextSaccadeAt: CFTimeInterval = 0

    private var expressionAnim: ExpressionAnimation?
    private var blinkAnim: FacialAnimation?
    private var saccadeAnim: FacialAnimation?
    private var eyeRollAnim: FacialAnimation?
    private var browAnim: FacialAnimation?

    // Shape names the lip-sync service owns during speech. We must not write to
    // these while it's animating or we get a tug-of-war on the mouth morphers.
    private let mouthKeys: Set<String> = [
        "jawOpen", "mouthClose", "mouthFunnel", "mouthPucker",
        "mouthSmileLeft", "mouthSmileRight",
        "mouthFrownLeft", "mouthFrownRight",
        "mouthStretchLeft", "mouthStretchRight",
        "mouthPressLeft", "mouthPressRight",
        "mouthLowerDownLeft", "mouthLowerDownRight",
        "mouthUpperUpLeft", "mouthUpperUpRight",
        "mouthRollLower", "mouthRollUpper",
        "mouthLeft", "mouthRight",
        "tongueOut",
        // Baked whole-face emotion shapes also drive the mouth, so we drop
        // them while lip-sync owns it. Brow/eye motion is lost during speech
        // as a side-effect; acceptable until we split the baked rig.
        "Joy", "Sadness", "Anger", "Shock", "Wonder", "Alertness",
        "Laughter", "Fear", "Disgust", "Melancholy", "Terror", "Satisfaction"
    ]

    private init() {}

    // MARK: - Configure

    func configure(buddyNode: SCNNode) {
        self.buddyNode = buddyNode
        rebuildMorpherCache()
        startDisplayLinkIfNeeded()
    }

    private func rebuildMorpherCache() {
        morphers.removeAll()
        indexCache.removeAll()
        lastWrittenKeys.removeAll()
        guard let root = buddyNode else { return }

        var collected: [SCNMorpher] = []
        root.enumerateHierarchy { node, _ in
            if let m = node.morpher,
               m.targets.count > 0,
               self.shouldUseMorpher(node, morpher: m) {
                collected.append(m)
            }
        }
        morphers = collected

        for morpher in morphers {
            var map: [String: Int] = [:]
            for (i, target) in morpher.targets.enumerated() {
                guard let name = target.name else { continue }
                map[name] = i
                let canonical = name.strippingTrailingDigits()
                if canonical != name && map[canonical] == nil {
                    map[canonical] = i
                }
            }
            indexCache.append(map)
        }
        print("[FacialExpression] Cached \(morphers.count) morphers for expressions")
        logFaceShapes()
    }

    /// Excludes body-only DAZ G9 morphers from upper-face expression writes.
    /// Aleda's body mesh carries a lone `jawOpen` morpher; touching it from the
    /// expression/lip-sync layers creates visible seams on the skin.
    private func shouldUseMorpher(_ node: SCNNode, morpher: SCNMorpher) -> Bool {
        let nodeName = node.name ?? ""
        let lowerName = nodeName.lowercased()
        let targetNames = morpher.targets.compactMap(\.name)
        let isGenesis9BodyLike =
            lowerName.contains("genesis9") &&
            !lowerName.contains("genesis9head") &&
            !lowerName.contains("genesis9mouth") &&
            !lowerName.contains("genesis9eyes") &&
            !lowerName.contains("genesis9eyelashes") &&
            !lowerName.contains("genesis9tear") &&
            !lowerName.contains("g9eyebrowfibers")

        let isDazBodyJawOnly =
            (nodeName == "Genesis9" || isGenesis9BodyLike) &&
            targetNames.count == 1 &&
            targetNames[0].strippingTrailingDigits() == "jawOpen"

        if isDazBodyJawOnly {
            return false
        }

        if isGenesis9BodyLike {
            return false
        }

        let hasFaceTargets = targetNames.contains { name in
            let canonical = name.strippingTrailingDigits().lowercased()
            return canonical.hasPrefix("eye") ||
                   canonical.hasPrefix("brow") ||
                   canonical.hasPrefix("cheek") ||
                   canonical.hasPrefix("nose") ||
                   canonical.hasPrefix("mouth") ||
                   canonical.hasPrefix("jaw") ||
                   canonical == "tongueout"
        }

        if lowerName.hasPrefix("genesis9mouth") ||
            lowerName.hasPrefix("genesis9head") ||
            lowerName.hasPrefix("g9eyebrowfibers") ||
            lowerName.hasPrefix("genesis9eyes") ||
            lowerName.hasPrefix("genesis9eyelashes") ||
            lowerName.hasPrefix("genesis9tear") {
            return hasFaceTargets
        }

        return true
    }

    /// Diagnostic: lists the brow/eye/cheek blendshape names actually present on
    /// the loaded mesh so we can confirm ARKit naming vs. a custom rig.
    private func logFaceShapes() {
        var found: Set<String> = []
        for map in indexCache {
            for name in map.keys {
                let lower = name.lowercased()
                if lower.hasPrefix("brow") || lower.hasPrefix("eye") || lower.hasPrefix("cheek") {
                    found.insert(name)
                }
            }
        }
        let sorted = found.sorted()
        print("[FacialExpression] Face shapes present (\(sorted.count)): \(sorted.joined(separator: ", "))")
    }

    // MARK: - Idle Behaviors

    func startIdleBehaviors() {
        idleRunning = true
        let now = CACurrentMediaTime()
        nextBlinkAt = now + Double.random(in: 3...6)
        nextSaccadeAt = now + Double.random(in: 2...5)
    }

    func stopIdleBehaviors() {
        idleRunning = false
        blinkAnim = nil
        saccadeAnim = nil
    }

    // MARK: - Public Triggers

    func setExpression(_ expression: Expression,
                       hold: TimeInterval = 1.5,
                       fadeIn: TimeInterval = 0.2,
                       fadeOut: TimeInterval = 0.4) {
        if expression == .neutral {
            expressionAnim = nil
            return
        }
        expressionAnim = ExpressionAnimation(expression: expression,
                                             fadeIn: fadeIn,
                                             hold: hold,
                                             fadeOut: fadeOut,
                                             startedAt: CACurrentMediaTime())
    }

    /// Clears any held expression immediately (used when the caller controls
    /// the lifetime — e.g. a chat response that wants to release emotion as
    /// soon as speech ends).
    func clearExpression(fadeOut: TimeInterval = 0.3) {
        guard let current = expressionAnim else { return }
        let now = CACurrentMediaTime()
        // Shrink the hold so the animation retires within `fadeOut`.
        expressionAnim = ExpressionAnimation(expression: current.expression,
                                             fadeIn: 0,
                                             hold: 0,
                                             fadeOut: fadeOut,
                                             startedAt: now)
    }

    func raiseEyebrow(_ brow: Brow, hold: TimeInterval = 2.0) {
        // Micoo's individual brow morph targets have very small vertex deltas;
        // push well past 1.0 so the motion is actually visible. For `.both` we
        // also blend in the baked "Wonder" shape which includes generous brow
        // lift by design.
        var shapes: [String: Float] = [:]
        switch brow {
        case .left:
            shapes["browOuterUpLeft"] = 2.5
            shapes["browInnerUp"] = 1.2
        case .right:
            shapes["browOuterUpRight"] = 2.5
            shapes["browInnerUp"] = 1.2
        case .both:
            shapes["Wonder"] = 0.7
            shapes["browOuterUpLeft"] = 2.0
            shapes["browOuterUpRight"] = 2.0
            shapes["browInnerUp"] = 1.5
        }
        browAnim = .fade(shapes: shapes,
                         fadeIn: 0.2,
                         hold: hold,
                         fadeOut: 0.4,
                         startedAt: CACurrentMediaTime())
    }

    func eyeRoll() {
        let start = CACurrentMediaTime()
        let keyframes: [FacialAnimation.Keyframe] = [
            .init(t: 0.00, weights: [:]),
            .init(t: 0.15, weights: ["eyeLookUpLeft": 1.0, "eyeLookUpRight": 1.0]),
            .init(t: 0.35, weights: ["eyeLookUpLeft": 0.5, "eyeLookUpRight": 0.5,
                                     "eyeLookOutLeft": 0.7, "eyeLookInRight": 0.7]),
            .init(t: 0.55, weights: ["eyeLookDownLeft": 0.7, "eyeLookDownRight": 0.7]),
            .init(t: 0.80, weights: [:])
        ]
        eyeRollAnim = FacialAnimation(keyframes: keyframes, startedAt: start)
    }

    // MARK: - Display Link

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let hasExplicitExpression = expressionAnim != nil || eyeRollAnim != nil

        // Idle scheduling — paused while an explicit expression is running.
        if idleRunning && !hasExplicitExpression {
            if blinkAnim == nil && now >= nextBlinkAt {
                blinkAnim = .fade(shapes: ["eyeBlinkLeft": 1.0, "eyeBlinkRight": 1.0],
                                  fadeIn: 0.08, hold: 0.04, fadeOut: 0.08,
                                  startedAt: now)
                // ~10 % chance of a quick second blink
                nextBlinkAt = (Double.random(in: 0...1) < 0.1)
                    ? now + 0.35
                    : now + Double.random(in: 3.5...6.0)
            }
            if saccadeAnim == nil && now >= nextSaccadeAt {
                saccadeAnim = .fade(shapes: randomSaccadeShapes(),
                                    fadeIn: 0.08, hold: 0.28, fadeOut: 0.15,
                                    startedAt: now)
                nextSaccadeAt = now + Double.random(in: 2.0...5.0)
            }
        }

        let speaking = SceneKitLipSyncService.shared.isAnimating

        // Sample every active animation and sum into one composited map.
        var composited: [String: Float] = [:]

        // Expression is resolved per-frame so we can swap preset variants when
        // lip-sync starts/stops mid-hold (baked full-face shapes look great on
        // their own but fight the mouth during speech — speech-safe variants
        // stick to brow/eye/cheek only).
        if let anim = expressionAnim {
            let envelope = anim.envelope(elapsed: now - anim.startedAt)
            if envelope > 0 {
                let preset = speaking
                    ? speechSafeWeights(for: anim.expression)
                    : weights(for: anim.expression)
                for (k, v) in preset {
                    composited[k, default: 0] += v * envelope
                }
            }
        }

        let other: [FacialAnimation?] = [eyeRollAnim, blinkAnim, saccadeAnim, browAnim]
        for anim in other {
            guard let a = anim, let sample = a.sample(elapsed: now - a.startedAt) else { continue }
            for (k, v) in sample {
                composited[k, default: 0] += v
            }
        }

        // Allow overshoot (>1.0) — Micoo's individual brow shapes barely
        // move at weight 1.0. Clamp at a safe ceiling to avoid runaway blends.
        for k in composited.keys { composited[k] = min(composited[k]!, 3.0) }

        // Lip-sync owns the mouth during speech — don't fight it.
        if speaking {
            for k in mouthKeys { composited.removeValue(forKey: k) }
        }

        // Retire finished animations.
        if let a = expressionAnim, now - a.startedAt > a.duration { expressionAnim = nil }
        if let a = eyeRollAnim,    now - a.startedAt > a.duration { eyeRollAnim = nil }
        if let a = blinkAnim,      now - a.startedAt > a.duration { blinkAnim = nil }
        if let a = saccadeAnim,    now - a.startedAt > a.duration { saccadeAnim = nil }
        if let a = browAnim,       now - a.startedAt > a.duration { browAnim = nil }

        applyWeights(composited)
    }

    private func randomSaccadeShapes() -> [String: Float] {
        let amount: Float = 0.18
        switch Int.random(in: 0..<4) {
        case 0: return ["eyeLookOutLeft": amount, "eyeLookInRight": amount]   // right
        case 1: return ["eyeLookInLeft": amount, "eyeLookOutRight": amount]   // left
        case 2: return ["eyeLookUpLeft": amount, "eyeLookUpRight": amount]    // up
        default: return ["eyeLookDownLeft": amount, "eyeLookDownRight": amount] // down
        }
    }

    private func applyWeights(_ weights: [String: Float]) {
        guard !morphers.isEmpty else { return }

        // Union of this frame's keys and last frame's keys — the previously
        // written ones must be explicitly zeroed if they're no longer active.
        let keysToWrite = lastWrittenKeys.union(weights.keys)
        for key in keysToWrite {
            let value = weights[key] ?? 0.0
            for (mi, map) in indexCache.enumerated() {
                if let index = map[key] {
                    morphers[mi].setWeight(CGFloat(value), forTargetAt: index)
                }
            }
        }
        lastWrittenKeys = Set(weights.keys)
    }

    // MARK: - Presets

    private func weights(for expression: Expression) -> [String: Float] {
        // Micoo ships with full-face baked emotion blendshapes (Joy, Sadness,
        // Anger, Shock, Wonder, Alertness, Laughter, Fear, Disgust, Melancholy,
        // Terror, Satisfaction). They already include matching brow/eye/mouth
        // motion, so driving them directly looks far better than composing from
        // raw ARKit shapes (which have tiny vertex deltas on this rig).
        switch expression {
        case .neutral:
            return [:]
        case .happy:
            return ["Joy": 1.0]
        case .sad:
            return ["Sadness": 1.0]
        case .angry:
            return ["Anger": 1.0]
        case .surprised:
            return ["Shock": 1.0]
        case .thinking:
            return ["Wonder": 0.6,
                    "eyeLookUpLeft": 0.3, "eyeLookUpRight": 0.3]
        case .skeptical:
            return ["Alertness": 0.8, "browOuterUpRight": 1.5]
        case .laughter:
            return ["Laughter": 1.0]
        case .fear:
            return ["Fear": 1.0]
        case .disgust:
            return ["Disgust": 1.0]
        case .melancholy:
            return ["Melancholy": 1.0]
        case .wonder:
            return ["Wonder": 1.0]
        }
    }

    /// Preset variant used while lip-sync is active. Only touches brow / eye /
    /// cheek / nose shapes — never the mouth — so visemes stay intact while
    /// the emotion still reads from the upper face.
    private func speechSafeWeights(for expression: Expression) -> [String: Float] {
        switch expression {
        case .neutral:
            return [:]
        case .happy:
            return [
                "eyeSquintLeft": 0.7, "eyeSquintRight": 0.7,
                "cheekSquintLeft": 1.2, "cheekSquintRight": 1.2,
                "browInnerUp": 1.2,
                "browOuterUpLeft": 0.6, "browOuterUpRight": 0.6
            ]
        case .laughter:
            // Stronger than happy: eyes almost closed, cheeks pushed up hard,
            // brows dancing up — reads clearly as "laughing" even with the
            // mouth doing viseme work.
            return [
                "eyeSquintLeft": 1.5, "eyeSquintRight": 1.5,
                "cheekSquintLeft": 2.0, "cheekSquintRight": 2.0,
                "browInnerUp": 1.6,
                "browOuterUpLeft": 1.2, "browOuterUpRight": 1.2,
                "noseSneerLeft": 0.4, "noseSneerRight": 0.4
            ]
        case .sad, .melancholy:
            return [
                "browInnerUp": 2.0,
                "browDownLeft": 0.4, "browDownRight": 0.4,
                "eyeLookDownLeft": 0.35, "eyeLookDownRight": 0.35
            ]
        case .angry:
            return [
                "browDownLeft": 2.5, "browDownRight": 2.5,
                "eyeSquintLeft": 0.9, "eyeSquintRight": 0.9,
                "noseSneerLeft": 0.7, "noseSneerRight": 0.7
            ]
        case .surprised, .wonder:
            return [
                "browInnerUp": 2.0,
                "browOuterUpLeft": 2.8, "browOuterUpRight": 2.8,
                "eyeWideLeft": 1.2, "eyeWideRight": 1.2
            ]
        case .fear:
            return [
                "browInnerUp": 2.2,
                "browOuterUpLeft": 1.5, "browOuterUpRight": 1.5,
                "eyeWideLeft": 1.3, "eyeWideRight": 1.3
            ]
        case .disgust:
            return [
                "noseSneerLeft": 1.4, "noseSneerRight": 1.4,
                "browDownLeft": 1.5, "browDownRight": 1.5,
                "eyeSquintLeft": 0.5, "eyeSquintRight": 0.5
            ]
        case .thinking:
            return [
                "browDownLeft": 0.7,
                "eyeLookUpLeft": 0.3, "eyeLookUpRight": 0.3
            ]
        case .skeptical:
            return [
                "browOuterUpRight": 2.2,
                "eyeSquintLeft": 0.4
            ]
        }
    }
}

// MARK: - Animation Primitives

/// Holds an `Expression` enum + timing envelope. The actual shape weights are
/// resolved per-frame by the service so it can swap full-face baked presets
/// for speech-safe (brow/eye only) variants when lip-sync starts mid-hold.
private struct ExpressionAnimation {
    let expression: FacialExpressionService.Expression
    let fadeIn: TimeInterval
    let hold: TimeInterval
    let fadeOut: TimeInterval
    let startedAt: CFTimeInterval

    var duration: TimeInterval { fadeIn + hold + fadeOut }

    func envelope(elapsed: TimeInterval) -> Float {
        if elapsed < 0 || elapsed > duration { return 0 }
        if elapsed < fadeIn {
            return fadeIn > 0 ? Float(elapsed / fadeIn) : 1
        }
        if elapsed < fadeIn + hold { return 1 }
        let remaining = duration - elapsed
        return fadeOut > 0 ? Float(remaining / fadeOut) : 0
    }
}

private struct FacialAnimation {
    struct Keyframe {
        let t: TimeInterval
        let weights: [String: Float]
    }

    let keyframes: [Keyframe]
    let startedAt: CFTimeInterval

    var duration: TimeInterval { keyframes.last?.t ?? 0 }

    static func fade(shapes: [String: Float],
                     fadeIn: TimeInterval,
                     hold: TimeInterval,
                     fadeOut: TimeInterval,
                     startedAt: CFTimeInterval) -> FacialAnimation {
        FacialAnimation(keyframes: [
            Keyframe(t: 0, weights: [:]),
            Keyframe(t: fadeIn, weights: shapes),
            Keyframe(t: fadeIn + hold, weights: shapes),
            Keyframe(t: fadeIn + hold + fadeOut, weights: [:])
        ], startedAt: startedAt)
    }

    func sample(elapsed: TimeInterval) -> [String: Float]? {
        guard elapsed >= 0, elapsed <= duration, keyframes.count >= 2 else { return nil }

        var prev = keyframes[0]
        var next = keyframes.last!
        for i in 0..<keyframes.count - 1 where keyframes[i].t <= elapsed && keyframes[i + 1].t >= elapsed {
            prev = keyframes[i]
            next = keyframes[i + 1]
            break
        }

        let span = next.t - prev.t
        let progress: Float = span > 0 ? Float((elapsed - prev.t) / span) : 1.0

        var out: [String: Float] = [:]
        let keys = Set(prev.weights.keys).union(next.weights.keys)
        for k in keys {
            let a = prev.weights[k] ?? 0
            let b = next.weights[k] ?? 0
            out[k] = a + (b - a) * progress
        }
        return out
    }
}

// MARK: - String Helper

private extension String {
    func strippingTrailingDigits() -> String {
        var r = self
        while r.last?.isNumber == true { r.removeLast() }
        return r
    }
}
