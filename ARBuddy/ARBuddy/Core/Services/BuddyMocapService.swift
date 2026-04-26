//
//  BuddyMocapService.swift
//  ARBuddy
//
//  Loads baked Mixamo-retargeted mocap animations (Genesis 9 bone names)
//  from `Animations/Mocap/<Clip>.usdz` and plays them on either a SceneKit
//  `SCNNode` (home preview) or a RealityKit `ModelEntity` (AR view).
//
//  The SceneKit side is the tricky one: SCNAnimationPlayer matches tracks
//  to bones via `keyPath`/node-name, so the retargeted clip only works if
//  its bone names match the live buddy's skeleton. The Blender retargeter
//  (skill: `daz-g9-to-usdz/scripts/retarget_mixamo.py`) bakes onto
//  Genesis-9-native names (hip, spine1, l_upperarm, …) so any G9-rigged
//  buddy can consume it.
//
//  Clips are loaded once and cached; multiple buddies reuse the same
//  player/animation resource — no per-buddy parse cost.
//
//  Falls back silently if the clip isn't in the bundle, so older buddies
//  without retargeted content simply keep running their procedural idle.
//

import Foundation
import SceneKit
import RealityKit

enum MocapClip: String, CaseIterable {
    case idleStandard = "Idle_Standard"
    case idle = "Idle"
    // future: talk, wave, …

    /// Clip played by default on freshly-loaded buddies. Change this to
    /// promote a new clip to the app-wide default without touching the
    /// call sites.
    static let `default`: MocapClip = .idleStandard

    /// Short human-readable label for debug UI.
    var displayName: String {
        switch self {
        case .idleStandard: return "Idle Standard"
        case .idle:         return "Idle (v1)"
        }
    }
}

@MainActor
final class BuddyMocapService {
    static let shared = BuddyMocapService()

    private init() {}

    /// Cache of per-clip SceneKit animations: per bone name, the attached
    /// `CAAnimation`-wrapping `SCNAnimation` ready for retargeting onto a
    /// live skeleton.
    private struct SceneKitClip {
        let tracks: [(boneName: String, animation: SCNAnimation)]
        let duration: TimeInterval
    }
    private var sceneKitCache: [MocapClip: SceneKitClip] = [:]

    /// Cache of RealityKit AnimationResources per clip.
    private var realityKitCache: [MocapClip: AnimationResource] = [:]

    /// Bundle subpath for mocap clip USDZs.
    private static let subdir = "Animations/Mocap"

    /// Weak ref to the SceneKit node of the most recently-played buddy.
    /// Lets debug/UI code switch clips at runtime via `switchClip(_:)`
    /// without threading the node through every call site.
    private weak var activeSceneKitNode: SCNNode?

    /// Currently playing clip on the SceneKit side, if any. Published so
    /// debug UI can reflect the active selection.
    private(set) var activeClip: MocapClip?

    // MARK: - SceneKit playback

    /// Plays `clip` on `buddyNode` by attaching per-bone animation players
    /// to each matching bone in the live skeleton. Returns true if at least
    /// one track was attached.
    @discardableResult
    func play(_ clip: MocapClip, on buddyNode: SCNNode, loop: Bool = true) -> Bool {
        guard let cached = sceneKitClip(for: clip) else {
            print("[BuddyMocap] SceneKit clip '\(clip.rawValue)' not loadable — skipping")
            return false
        }

        // Switching clips: stop the previous one so tracks from two clips
        // don't stack on the same bones.
        stop(on: buddyNode)

        var attached = 0
        var missing: [String] = []
        for (boneName, anim) in cached.tracks {
            guard let target = buddyNode.childNode(withName: boneName, recursively: true) else {
                if missing.count < 4 { missing.append(boneName) }
                continue
            }
            let key = "mocap_\(clip.rawValue)_\(boneName)"
            target.removeAnimation(forKey: key)

            // Clone animation so repeat/blend settings are per-play, not shared.
            let player = SCNAnimationPlayer(animation: anim)
            player.speed = 1.0
            anim.repeatCount = loop ? .greatestFiniteMagnitude : 1
            anim.isRemovedOnCompletion = !loop
            anim.blendInDuration = 0.15

            target.addAnimationPlayer(player, forKey: key)
            player.play()
            attached += 1
        }

        if attached > 0 {
            activeSceneKitNode = buddyNode
            activeClip = clip
        }

        let suffix = missing.isEmpty ? "" : " (missing e.g. \(missing.joined(separator: ", ")))"
        print("[BuddyMocap] SceneKit \(clip.rawValue): \(attached)/\(cached.tracks.count) tracks\(suffix)")
        return attached > 0
    }

    /// Switch to a different clip on the previously-configured buddy node.
    /// Used by the DEBUG animation picker in the preview. No-op if no
    /// buddy has been set up yet.
    @discardableResult
    func switchClip(_ clip: MocapClip) -> Bool {
        guard let node = activeSceneKitNode else {
            print("[BuddyMocap] switchClip(\(clip.rawValue)): no active buddy node")
            return false
        }
        return play(clip, on: node, loop: true)
    }

    /// Removes any playing mocap clips from the buddy skeleton.
    func stop(on buddyNode: SCNNode) {
        buddyNode.enumerateHierarchy { node, _ in
            for key in node.animationKeys where key.hasPrefix("mocap_") {
                node.removeAnimation(forKey: key)
            }
        }
    }

    /// Tear-down before swapping buddies: stop all clips on the outgoing
    /// node and drop both caches. The cached `SCNAnimation`s reference
    /// bone-name paths from the previous skeleton; keeping them around
    /// wastes RAM and risks re-binding onto a different character.
    func stopAndFlush(on buddyNode: SCNNode?) {
        if let buddyNode {
            stop(on: buddyNode)
        }
        sceneKitCache.removeAll()
        realityKitCache.removeAll()
        activeSceneKitNode = nil
        activeClip = nil
    }

    private func sceneKitClip(for clip: MocapClip) -> SceneKitClip? {
        if let cached = sceneKitCache[clip] { return cached }

        guard let url = Bundle.main.url(
            forResource: clip.rawValue,
            withExtension: "usdz",
            subdirectory: Self.subdir
        ) ?? Bundle.main.url(forResource: clip.rawValue, withExtension: "usdz") else {
            return nil
        }

        let scene: SCNScene
        do {
            scene = try SCNScene(url: url, options: [
                .animationImportPolicy: SCNSceneSource.AnimationImportPolicy.playRepeatedly
            ])
        } catch {
            print("[BuddyMocap] Load failed for \(clip.rawValue): \(error)")
            return nil
        }

        var collected: [(String, SCNAnimation)] = []
        var maxDuration: TimeInterval = 0
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let name = node.name, !name.isEmpty else { return }
            for key in node.animationKeys {
                guard let player = node.animationPlayer(forKey: key) else { continue }
                let anim = player.animation
                collected.append((name, anim))
                maxDuration = max(maxDuration, anim.duration)
            }
        }

        guard !collected.isEmpty else {
            print("[BuddyMocap] \(clip.rawValue): USDZ parsed but no animation tracks found")
            return nil
        }

        let packed = SceneKitClip(tracks: collected, duration: maxDuration)
        sceneKitCache[clip] = packed
        print("[BuddyMocap] SceneKit \(clip.rawValue): cached \(collected.count) tracks, \(String(format: "%.2f", maxDuration))s")
        return packed
    }

    // MARK: - RealityKit playback

    /// Plays `clip` on a RealityKit entity. Returns true if an animation
    /// was attached.
    @discardableResult
    func play(_ clip: MocapClip, on entity: Entity, loop: Bool = true) -> Bool {
        let hasExternalClipAsset = realityKitClipURL(for: clip) != nil
        let resource: AnimationResource?
        if let cached = realityKitCache[clip] {
            resource = cached
        } else if let loaded = loadRealityKit(clip) {
            realityKitCache[clip] = loaded
            resource = loaded
        } else {
            resource = nil
        }

        // Prefer the requested mocap resource. Falling back to the entity's
        // own embedded animation keeps older assets alive when no external
        // clip is available, but must not shadow an explicitly loaded clip.
        if resource == nil, hasExternalClipAsset {
            print("[BuddyMocap] RealityKit \(clip.rawValue): external clip asset exists but has no usable animation")
            return false
        }

        let anim = resource ?? entity.availableAnimations.first
        guard let playable = anim else {
            print("[BuddyMocap] RealityKit \(clip.rawValue): no animation found")
            return false
        }

        let final: AnimationResource = loop ? playable.repeat() : playable
        entity.playAnimation(final, transitionDuration: 0.25, startsPaused: false)
        print("[BuddyMocap] RealityKit \(clip.rawValue): playing (loop=\(loop))")
        return true
    }

    private func loadRealityKit(_ clip: MocapClip) -> AnimationResource? {
        guard let url = realityKitClipURL(for: clip) else {
            return nil
        }
        do {
            // Mocap USDZs are animation scenes, not always a single ModelEntity
            // root. Loading through Entity avoids RealityKit's wrongEntityType
            // failure and lets us search the full hierarchy for the clip.
            let entity = try Entity.load(contentsOf: url)
            if let animation = firstAnimation(in: entity) {
                return animation
            }
            print("[BuddyMocap] RealityKit \(clip.rawValue): USDZ loaded but no animation found")
            return nil
        } catch {
            print("[BuddyMocap] RealityKit load failed for \(clip.rawValue): \(error)")
            return nil
        }
    }

    private func firstAnimation(in entity: Entity) -> AnimationResource? {
        if let animation = entity.availableAnimations.first {
            return animation
        }

        for child in entity.children {
            if let animation = firstAnimation(in: child) {
                return animation
            }
        }

        return nil
    }

    private func realityKitClipURL(for clip: MocapClip) -> URL? {
        Bundle.main.url(
            forResource: clip.rawValue,
            withExtension: "usdz",
            subdirectory: Self.subdir
        ) ?? Bundle.main.url(forResource: clip.rawValue, withExtension: "usdz")
    }
}
