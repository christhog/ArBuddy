//
//  BuddyGestureService.swift
//  ARBuddy
//
//  Procedural animation dispatch for the buddy.
//
//  **Idle** is a stack of independent SCNAction loops running on different
//  bones with different action keys so they compose:
//    - root: breathing (Y bob) + yaw wobble + slow weight shift (X sway)
//    - shoulder_l / shoulder_r: opposite-phase arm sway
//
//  **Gestures** are short, one-shot SCNActions targeting head / spine /
//  shoulders / hands / root as appropriate. They overlay on top of the
//  idle because each uses its own action key; when the gesture finishes
//  the underlying idle action keeps running and brings the bone back to
//  neutral.
//
//  An **ambient scheduler** fires a random procedural fidget every
//  ~9s (± jitter) so the preview feels alive between sentences. It
//  pauses whenever the chat pipeline calls `setSpeaking(true)`.
//
//  A baked-USDZ layer was originally planned (wave / blowKiss / etc.
//  clips authored in Blender). Blender 5.1's USD-Skel exporter produces
//  USDZ files that iOS SceneKit cannot parse as rigged (no skinner, no
//  animation tracks), so the pipeline is dormant: enum cases stay, clip
//  files exist in the bundle, but `loadBakedClip` returns nil and
//  `playBaked` routes to a procedural fallback. Re-enable by replacing
//  the USDZ files with ones authored via a working pipeline (Reality
//  Composer Pro FBX→USDZ roundtrip, or similar).
//
//  This coexists with blendshape-driven facial expressions and lip sync
//  because those touch a different layer (SCNMorpher weights), not the
//  skeleton/transform.
//

import Foundation
import SceneKit

@MainActor
final class BuddyGestureService {
    static let shared = BuddyGestureService()

    private init() {}

    private weak var buddyNode: SCNNode?
    private var buddyId: String = ""

    /// Set to true when a baked mocap clip (via `BuddyMocapService`) is
    /// driving the body skeleton. Suppresses the procedural body-idle
    /// layers (breathing, yaw, weight-shift, arm-sway) that would otherwise
    /// fight the mocap tracks. Hair-strand idle, ambient procedural
    /// gestures (if any remain allowed), blendshape facial expressions and
    /// lip-sync continue unaffected — different layers.
    var isMocapDriven: Bool = false

    /// Ratio of the current buddy's world-space height to Micoo's (~8 m).
    /// Amplitudes for translation-based idle actions (breathing Y-bob,
    /// weight-shift X-sway) were originally tuned for Micoo; for smaller
    /// buddies like Aleda (~0.8 m) the raw values would move the buddy
    /// right out of frame. Rotations are scale-invariant so they stay.
    private var heightScale: CGFloat = 1.0
    private let micooBaselineHeight: CGFloat = 8.0
    private weak var headBone: SCNNode?
    private weak var spineBone: SCNNode?
    // Arm + leg deform bones so we can fidget, sway, shift weight, stretch…
    // Not all rigs expose these; missing bones just skip their contribution.
    private weak var shoulderLBone: SCNNode?
    private weak var shoulderRBone: SCNNode?
    // Upper-arm deform bone — the actual root of the arm chain. In ARP the
    // clavicle (`shoulder_l`) does NOT parent the arm; the arm is siblings or
    // lives deeper. Rotating this bone moves upper arm + forearm + hand as a
    // unit via parent-child transform.
    private weak var upperArmLBone: SCNNode?
    private weak var upperArmRBone: SCNNode?
    // ARP splits the upper-arm deform into three parallel bones (stretch +
    // two twist bones) that Blender's constraints normally keep in sync.
    // Those constraints don't survive USDZ, so we keep references to ALL of
    // them and rotate them in lockstep so the mesh doesn't tear.
    private weak var armStretchLBone: SCNNode?
    private weak var armTwist1LBone: SCNNode?
    private weak var armTwist2LBone: SCNNode?
    private weak var armStretchRBone: SCNNode?
    private weak var armTwist1RBone: SCNNode?
    private weak var armTwist2RBone: SCNNode?
    // Forearm deform bone — parented to `c_traj` (global root), NOT to the
    // upper arm, so it doesn't inherit upper-arm rotation. We rotate it
    // separately with a compatible angle to keep the arm visually coherent.
    private weak var forearmLBone: SCNNode?
    private weak var forearmRBone: SCNNode?
    private weak var handLBone: SCNNode?
    private weak var handRBone: SCNNode?
    private weak var thighLBone: SCNNode?
    private weak var thighRBone: SCNNode?
    private weak var footLBone: SCNNode?
    private weak var footRBone: SCNNode?

    /// Optional hair-strand deform bones (DAZ GlamourStyle naming:
    /// `lBack*`, `rBack*`, `lBangs*`, `rBangs*`, `lFront*`, `rFront*`).
    /// Found opportunistically during `configure`; empty for rigs without
    /// hair strands. Animated via `startHairIdle` with per-bone random
    /// phase offsets so the hair breathes gently instead of moving in sync.
    private var hairBones: [SCNNode] = []

    private let idleKey = "buddy_idle"
    private let idleHairKeyPrefix = "buddy_idle_hair_"
    private let idleArmLKey = "buddy_idle_arm_l"
    private let idleArmRKey = "buddy_idle_arm_r"
    private let idleWeightKey = "buddy_idle_weight"
    private let gestureKey = "buddy_gesture"
    private let headGestureKey = "buddy_gesture_head"
    private let armLGestureKey = "buddy_gesture_arm_l"
    private let armRGestureKey = "buddy_gesture_arm_r"
    private let bakedKey = "buddy_baked"

    /// Cache of loaded baked animations, keyed by clip filename (without
    /// extension). Each clip is a list of per-bone tracks with the source
    /// node's name; on playback we retarget each track to the same-named
    /// bone in the live buddy skeleton. First play pays the USDZ-parse cost
    /// once.
    private struct BakedClip {
        let tracks: [(nodeName: String, animation: SCNAnimation)]
        let duration: TimeInterval
    }
    private var bakedCache: [String: BakedClip] = [:]

    // MARK: - Ambient scheduler state

    private var isSpeaking: Bool = false
    private var ambientTimer: Timer?
    /// Whether a baked gesture is currently playing — blocks overlapping
    /// baked triggers (the mesh can only bend one way at a time).
    private var bakedPlaybackEndsAt: Date = .distantPast

    // MARK: - Configuration

    /// Finds the first child node whose name matches any of `candidates`.
    /// Used to locate skeleton bones by their well-known ARP/Mixamo names
    /// without hardcoding a buddy-specific path.
    private static func findBone(in node: SCNNode, named candidates: [String]) -> SCNNode? {
        for name in candidates {
            if let found = node.childNode(withName: name, recursively: true) {
                return found
            }
        }
        return nil
    }

    /// Updates the world-height used to scale translation amplitudes.
    /// Called from the buddy preview once the bounding box has been
    /// computed (which happens asynchronously after USDZ load); callers
    /// should then restart the idle so running actions pick up the new
    /// scale.
    func updateWorldHeight(_ height: CGFloat) {
        guard height > 0 else { return }
        heightScale = height / micooBaselineHeight
    }

    func configure(buddyNode: SCNNode, buddyId: String = "Micoo", worldHeight: CGFloat? = nil) {
        self.buddyNode = buddyNode
        self.buddyId = buddyId
        if let h = worldHeight, h > 0 {
            self.heightScale = h / micooBaselineHeight
        } else {
            self.heightScale = 1.0
        }

        // Head deform bone (Auto-Rig Pro uses `head_x` for the skinned bone,
        // `c_head_x` for the animator's control; Mixamo uses `mixamorig_Head`).
        // We rotate the one that actually moves the mesh, preferring the
        // deform bone.
        self.headBone = Self.findBone(in: buddyNode, named: [
            "head_x", "c_head_x", "mixamorig_Head", "Head", "head"
        ])

        // Upper spine — used for bow. ARP splits spine into 3 segments;
        // `spine_03_x` is the uppermost which gives a nice bend pivot.
        self.spineBone = Self.findBone(in: buddyNode, named: [
            "spine_03_x", "c_spine_03_x", "spine_02_x", "c_spine_02_x",
            "mixamorig_Spine2", "mixamorig_Spine1", "Spine2", "Spine1"
        ])

        // Arms — we rotate the CLAVICLE (`shoulder_l/r`). Blender's rig
        // constraints (FK→deform, twist-copy, IK) don't survive USD export;
        // in SceneKit every bone is independent. That means rotating the
        // FK control `c_arm_fk_l` does nothing visible (it's not a skinning
        // bone), and rotating a single deform bone like `arm_stretch_l`
        // tears the mesh because its sibling twist bones stay still.
        //
        // The clavicle is the PARENT of the whole arm deform chain, so
        // rotating it moves every arm bone in unison via plain parent-child
        // transform propagation — no constraints needed, no tearing. The
        // motion reads as a shoulder roll carrying the arm along, which is
        // close enough to a natural "schlendern" swing.
        self.shoulderLBone = Self.findBone(in: buddyNode, named: [
            "shoulder_l", "clavicle_l",
            "mixamorig_LeftShoulder", "LeftShoulder"
        ])
        self.shoulderRBone = Self.findBone(in: buddyNode, named: [
            "shoulder_r", "clavicle_r",
            "mixamorig_RightShoulder", "RightShoulder"
        ])

        // Upper-arm deform bone — this is what we actually rotate for arm
        // sway. Diagnostic revealed that `shoulder_l`'s children are only
        // helpers (`shoulder_track_pole_l`, `arm_twist_twk_l`) — the real arm
        // chain (`arm_l/arm_stretch_l → forearm_l → hand_l`) lives elsewhere
        // in the hierarchy, so rotating the clavicle barely moves any mesh.
        // `arm_l` is typically the top of the deform arm chain in ARP;
        // `arm_stretch_l` is the fallback.
        self.upperArmLBone = Self.findBone(in: buddyNode, named: [
            "arm_l", "arm_stretch_l",
            "mixamorig_LeftArm", "LeftArm", "upperarm_l"
        ])
        self.upperArmRBone = Self.findBone(in: buddyNode, named: [
            "arm_r", "arm_stretch_r",
            "mixamorig_RightArm", "RightArm", "upperarm_r"
        ])

        // The full upper-arm deform "bundle" — these bones all skin the upper
        // arm mesh. We drive them together so rotation doesn't tear the mesh.
        self.armStretchLBone = Self.findBone(in: buddyNode, named: ["arm_stretch_l"])
        self.armTwist1LBone  = Self.findBone(in: buddyNode, named: ["arm_twist_l"])
        self.armTwist2LBone  = Self.findBone(in: buddyNode, named: ["arm_twist_2_l"])
        self.armStretchRBone = Self.findBone(in: buddyNode, named: ["arm_stretch_r"])
        self.armTwist1RBone  = Self.findBone(in: buddyNode, named: ["arm_twist_r"])
        self.armTwist2RBone  = Self.findBone(in: buddyNode, named: ["arm_twist_2_r"])
        self.forearmLBone    = Self.findBone(in: buddyNode, named: ["forearm_l"])
        self.forearmRBone    = Self.findBone(in: buddyNode, named: ["forearm_r"])

        // Hands, thighs, feet — use the actual DEFORM bones, same reasoning
        // as for the clavicle above. ARP's `c_*_fk_*` controls are useless
        // at runtime since their constraint relationships don't survive
        // USDZ export.
        self.handLBone = Self.findBone(in: buddyNode, named: [
            "hand_l", "mixamorig_LeftHand", "LeftHand"
        ])
        self.handRBone = Self.findBone(in: buddyNode, named: [
            "hand_r", "mixamorig_RightHand", "RightHand"
        ])
        self.thighLBone = Self.findBone(in: buddyNode, named: [
            "thigh_l", "mixamorig_LeftUpLeg", "LeftUpLeg"
        ])
        self.thighRBone = Self.findBone(in: buddyNode, named: [
            "thigh_r", "mixamorig_RightUpLeg", "RightUpLeg"
        ])
        self.footLBone = Self.findBone(in: buddyNode, named: [
            "foot_l", "mixamorig_LeftFoot", "LeftFoot"
        ])
        self.footRBone = Self.findBone(in: buddyNode, named: [
            "foot_r", "mixamorig_RightFoot", "RightFoot"
        ])

        // Hair strand bones — DAZ GlamourStyle-style hair ships with named
        // strand chains (`lBack01`, `rBangs02`, …) re-parented to `head`
        // during Blender import. We grab every bone whose name starts with
        // one of the known prefixes so `startHairIdle` can drive them.
        // Missing hair bones = empty list, hair idle becomes a no-op.
        let hairPrefixes = ["lBack", "rBack", "lBangs", "rBangs", "lFront", "rFront"]
        var collectedHair: [SCNNode] = []
        buddyNode.enumerateHierarchy { node, _ in
            guard let n = node.name else { return }
            if hairPrefixes.contains(where: { n.hasPrefix($0) }) {
                collectedHair.append(node)
            }
        }
        self.hairBones = collectedHair

        print("[BuddyGesture] bones — head=\(headBone?.name ?? "nil"), spine=\(spineBone?.name ?? "nil"), shL=\(shoulderLBone?.name ?? "nil"), shR=\(shoulderRBone?.name ?? "nil"), thL=\(thighLBone?.name ?? "nil"), thR=\(thighRBone?.name ?? "nil"), ftL=\(footLBone?.name ?? "nil"), ftR=\(footRBone?.name ?? "nil"), hair=\(hairBones.count)")

        // Pull a few extra bones by name just for the diagnostic, so we can
        // see whether the arm deform chain is parented (arm → forearm → hand)
        // or flat (each deform bone hanging off a control with no chain).
        let extras: [SCNNode?] = [
            Self.findBone(in: buddyNode, named: ["arm_stretch_l"]),
            Self.findBone(in: buddyNode, named: ["arm_stretch_r"]),
            Self.findBone(in: buddyNode, named: ["arm_twist_l"]),
            Self.findBone(in: buddyNode, named: ["arm_twist_2_l"]),
            Self.findBone(in: buddyNode, named: ["forearm_l"]),
            Self.findBone(in: buddyNode, named: ["forearm_r"]),
            Self.findBone(in: buddyNode, named: ["forearm_stretch_l"]),
        ]
        Self.dumpArmDiagnostics(root: buddyNode, candidates: [
            shoulderLBone, shoulderRBone,
            upperArmLBone, upperArmRBone,
            handLBone, handRBone,
        ] + extras)

    }

    /// One-shot diagnostic. For each candidate bone logs:
    ///   - its parent's name (so we can see if rotating it actually propagates
    ///     anywhere useful),
    ///   - its direct children (to confirm the arm chain is actually parented
    ///     under it — if not, rotating this bone does nothing to the arm),
    ///   - whether it appears in any SCNSkinner's bone array (= is a true
    ///     deform bone carrying mesh weights).
    ///
    /// Also lists every bone in the hierarchy whose name contains "shoulder",
    /// "clavic", or "arm" so we can see all candidate names in one place —
    /// the `_x`-suffixed deform variant is usually the one we actually need.
    private static func dumpArmDiagnostics(root: SCNNode, candidates: [SCNNode?]) {
        // Collect every bone referenced by every SCNSkinner in the tree.
        var skinnerBoneNames = Set<String>()
        root.enumerateHierarchy { node, _ in
            guard let skinner = node.skinner else { return }
            for bone in skinner.bones {
                if let n = bone.name { skinnerBoneNames.insert(n) }
            }
        }
        print("[BuddyGesture/diag] skinner bones total=\(skinnerBoneNames.count)")

        for candidate in candidates.compactMap({ $0 }) {
            let name = candidate.name ?? "<unnamed>"
            let parent = candidate.parent?.name ?? "<none>"
            let children = candidate.childNodes.compactMap { $0.name }.joined(separator: ", ")
            let skinned = skinnerBoneNames.contains(name) ? "YES" : "NO"
            print("[BuddyGesture/diag] \(name): parent=\(parent) skinned=\(skinned) children=[\(children)]")
        }

        // Dump every bone whose name hints at arm/shoulder/clavicle so we can
        // spot the `_x` deform variant or an alternative naming scheme.
        var armLike: [String] = []
        root.enumerateHierarchy { node, _ in
            guard let n = node.name?.lowercased() else { return }
            if n.contains("shoulder") || n.contains("clavic") || n.contains("arm") {
                armLike.append(node.name ?? "")
            }
        }
        print("[BuddyGesture/diag] arm-like bone names: \(armLike)")
    }

    // MARK: - Idle

    /// Starts a layered idle: breathing + yaw on the root, slow arm sway on
    /// both shoulders (opposite phase so it reads like someone waiting), and
    /// a very gentle weight-shift on the root. Each layer runs on its own
    /// action key so they compose without cancelling each other out, and
    /// missing bones just skip their layer.
    func startIdle() {
        guard let node = buddyNode else { return }
        node.removeAction(forKey: idleKey)
        upperArmLBone?.removeAction(forKey: idleArmLKey)
        upperArmRBone?.removeAction(forKey: idleArmRKey)
        node.removeAction(forKey: idleWeightKey)

        // Under mocap: skip every body layer so the baked skeleton animation
        // is the sole driver. Hair-strand idle still runs — hair is not part
        // of the mocap clip. Ambient scheduler also starts so procedural
        // fidgets can layer in later if we ever allow them under mocap
        // (currently blocked inside `play(_:)`).
        if isMocapDriven {
            startHairIdle()
            startAmbientScheduler()
            return
        }

        // --- Root layer: breathing + soft yaw + weight shift ---

        // Breathing: ~+-3cm on Y at Micoo (8m) scale, scaled down for
        // smaller buddies so it stays readable without drifting them.
        let breatheAmp = 0.03 * heightScale
        let breatheUp = SCNAction.moveBy(x: 0, y: breatheAmp, z: 0, duration: 1.4)
        breatheUp.timingMode = .easeInEaseOut
        let breatheDown = SCNAction.moveBy(x: 0, y: -breatheAmp, z: 0, duration: 1.4)
        breatheDown.timingMode = .easeInEaseOut
        let breathe = SCNAction.sequence([breatheUp, breatheDown])

        // Slow yaw wobble — ~1.5° over 5.4s.
        let yawRight = SCNAction.rotateBy(x: 0, y: 0.026, z: 0, duration: 2.7)
        yawRight.timingMode = .easeInEaseOut
        let yawLeft = SCNAction.rotateBy(x: 0, y: -0.026, z: 0, duration: 2.7)
        yawLeft.timingMode = .easeInEaseOut
        let yaw = SCNAction.sequence([yawRight, yawLeft])

        let group = SCNAction.group([
            SCNAction.repeatForever(breathe),
            SCNAction.repeatForever(yaw),
        ])
        node.runAction(group, forKey: idleKey)

        // Weight shift — gentle sway ~10cm left/right around centre at
        // Micoo (8m) scale, ~9s cycle. Symmetric around origin so the
        // buddy doesn't drift to one side over time. Scaled to buddy size
        // so smaller models don't slide right out of frame.
        let swayAmp = 0.1 * heightScale
        let shiftL = SCNAction.moveBy(x: -swayAmp, y: 0, z: 0, duration: 1.4)
        shiftL.timingMode = .easeInEaseOut
        let holdL = SCNAction.wait(duration: 2.0)
        let shiftR = SCNAction.moveBy(x: swayAmp * 2, y: 0, z: 0, duration: 1.4)
        shiftR.timingMode = .easeInEaseOut
        let holdR = SCNAction.wait(duration: 2.0)
        let recenter = SCNAction.moveBy(x: -swayAmp, y: 0, z: 0, duration: 1.2)
        recenter.timingMode = .easeInEaseOut
        let weightCycle = SCNAction.sequence([shiftL, holdL, shiftR, holdR, recenter])
        node.runAction(SCNAction.repeatForever(weightCycle), forKey: idleWeightKey)

        // --- Arm sway.
        //
        // Rig reality (from runtime diagnostic):
        //   c_shoulder_l → arm_twist_l → arm_stretch_l → arm_twist_2_l
        //   forearm_l    parent=c_traj (global root, NOT linked to upper arm)
        //   hand_l       parent=forearm_l
        //
        // So the upper arm IS a real chain — rotating `arm_twist_l` (the
        // root) cascades to arm_stretch and arm_twist_2 via parent-child.
        // Rotating the children too would double the rotation and tear
        // the mesh, which is exactly what the smoke test showed.
        //
        // The forearm chain is broken off at `c_traj`, so if we rotate
        // only the upper arm, the forearm+hand stay glued in the rest pose
        // and the arm looks dislocated. We mirror the same rotation onto
        // `forearm_l` so the whole arm swings as a unit, at the cost of a
        // slightly stiff elbow (real humans bend the elbow during a swing,
        // but "straight arm swing" still reads as natural idle).
        //
        // Amplitude on X only — Z rotation on arm_twist_l would pitch the
        // arm sideways through the torso, which we saw as the "totally
        // unnatural" deformation.
        let s = CGFloat(0.2)   // ~11° forward-back swing
        if let armRoot = armTwist1LBone {
            let fwd = SCNAction.rotateBy(x: s, y: 0, z: 0, duration: 2.5)
            fwd.timingMode = .easeInEaseOut
            let back = SCNAction.rotateBy(x: -s, y: 0, z: 0, duration: 2.5)
            back.timingMode = .easeInEaseOut
            armRoot.runAction(SCNAction.repeatForever(SCNAction.sequence([fwd, back])), forKey: idleArmLKey)
        }
        if let fore = forearmLBone {
            // Same rotation as upper arm so the forearm stays aligned.
            let fwd = SCNAction.rotateBy(x: s, y: 0, z: 0, duration: 2.5)
            fwd.timingMode = .easeInEaseOut
            let back = SCNAction.rotateBy(x: -s, y: 0, z: 0, duration: 2.5)
            back.timingMode = .easeInEaseOut
            fore.runAction(SCNAction.repeatForever(SCNAction.sequence([fwd, back])), forKey: idleArmLKey + "_fore")
        }
        if let armRoot = armTwist1RBone {
            // Opposite phase (back while left is fwd) so it reads like a stroll.
            let back = SCNAction.rotateBy(x: -s, y: 0, z: 0, duration: 2.5)
            back.timingMode = .easeInEaseOut
            let fwd = SCNAction.rotateBy(x: s, y: 0, z: 0, duration: 2.5)
            fwd.timingMode = .easeInEaseOut
            armRoot.runAction(SCNAction.repeatForever(SCNAction.sequence([back, fwd])), forKey: idleArmRKey)
        }
        if let fore = forearmRBone {
            let back = SCNAction.rotateBy(x: -s, y: 0, z: 0, duration: 2.5)
            back.timingMode = .easeInEaseOut
            let fwd = SCNAction.rotateBy(x: s, y: 0, z: 0, duration: 2.5)
            fwd.timingMode = .easeInEaseOut
            fore.runAction(SCNAction.repeatForever(SCNAction.sequence([back, fwd])), forKey: idleArmRKey + "_fore")
        }

        startHairIdle()
        startAmbientScheduler()
    }

    func stopIdle() {
        buddyNode?.removeAction(forKey: idleKey)
        buddyNode?.removeAction(forKey: idleWeightKey)
        armTwist1LBone?.removeAction(forKey: idleArmLKey)
        armTwist1RBone?.removeAction(forKey: idleArmRKey)
        forearmLBone?.removeAction(forKey: idleArmLKey + "_fore")
        forearmRBone?.removeAction(forKey: idleArmRKey + "_fore")
        for (i, bone) in hairBones.enumerated() {
            bone.removeAction(forKey: idleHairKeyPrefix + String(i))
        }
        stopAmbientScheduler()
    }

    /// Very subtle idle sway on every hair-strand bone. Each bone gets a
    /// ~3° X-axis rotation loop with a per-bone randomized duration (2.8–4.2s)
    /// and a randomized starting-phase delay (0–1.5s) so the strands don't
    /// swing in unison — they look like gentle gravity-settled hair, not a
    /// marching band. No-op if the rig has no hair bones.
    private func startHairIdle() {
        guard !hairBones.isEmpty else { return }
        for (i, bone) in hairBones.enumerated() {
            let key = idleHairKeyPrefix + String(i)
            bone.removeAction(forKey: key)

            let amp = CGFloat(Float.random(in: 0.04...0.07))   // ~2.3°–4° on X
            let period = Double.random(in: 2.8...4.2)
            let phase = Double.random(in: 0...1.5)

            let forward = SCNAction.rotateBy(x: amp, y: 0, z: 0, duration: period / 2)
            forward.timingMode = .easeInEaseOut
            let back = SCNAction.rotateBy(x: -amp, y: 0, z: 0, duration: period / 2)
            back.timingMode = .easeInEaseOut
            let loop = SCNAction.repeatForever(SCNAction.sequence([forward, back]))

            let delayed = SCNAction.sequence([SCNAction.wait(duration: phase), loop])
            bone.runAction(delayed, forKey: key)
        }
    }

    // MARK: - Gestures

    /// Vocabulary the chat pipeline (and the LLM via `[gesture:xxx]` markers)
    /// can trigger. Procedural cases are hand-tuned SCNActions; baked cases
    /// are full-body USDZ clips authored in Blender.
    enum Gesture: String, CaseIterable {
        // Procedural (SCNAction)
        case nod
        case shake
        case jump
        case cheer
        case bow
        case wiggle
        case lookLeft
        case lookRight
        // Ambient-friendly fidgets
        case armStretch        // both arms briefly rise
        case weightShift       // exaggerated single-foot weight shift
        case headTilt          // curious sideways tilt
        case handFidget        // subtle wrist wiggle
        case impatient         // combined weight-shift + head-shake — "come on…"

        // Baked (USDZ clips under Animations/Micoo/) — currently disabled
        // because Blender 5.1's USD Skel export doesn't yield SceneKit-
        // readable animation tracks. Cases stay so the LLM marker parser
        // and the service API keep their vocabulary; `bakedClipName` still
        // returns the filename but `playBaked` now logs a skip instead of
        // crashing. Re-enable once the USDZ pipeline produces working clips
        // (e.g. Reality Composer Pro roundtrip).
        case wave
        case blowKiss
        case yesJump
        case thinking
        case dontKnow
        case shy
        case pointLeft
        case pointUp
        case pointDown
        case frustration
        case crossedArms
        case awake

        static func fromMarker(_ raw: String) -> Gesture? {
            Gesture(rawValue: raw.lowercased())
                ?? Gesture.allCases.first { $0.rawValue.lowercased() == raw.lowercased() }
        }

        /// Matching USDZ filename (without extension) for baked clips.
        var bakedClipName: String? {
            switch self {
            case .wave:         return "Wave"
            case .blowKiss:     return "BlowKiss"
            case .yesJump:      return "YesJump"
            case .thinking:     return "Thinking"
            case .dontKnow:     return "DontKnow"
            case .shy:          return "Shy"
            case .pointLeft:    return "PointLeft"
            case .pointUp:      return "PointUp"
            case .pointDown:    return "PointDown"
            case .frustration:  return "Frustration"
            case .crossedArms:  return "CrossedArms"
            case .awake:        return "Awake"
            default:            return nil
            }
        }

        var isBaked: Bool { bakedClipName != nil }
    }

    /// Plays `gesture` once. Head-only procedural gestures drive the head
    /// bone so they stay local; bow drives the upper spine; body gestures
    /// drive the root. Baked gestures load a CAAnimation from bundle and
    /// attach it to the buddy's root (SceneKit retargets by bone name).
    func play(_ gesture: Gesture) {
        guard let root = buddyNode else { return }

        // When mocap is driving the body, procedural gestures that touch
        // the skeleton (arm-stretch, weight-shift, nod, …) would tear the
        // mesh or fight the mocap channels. First iteration: suppress
        // entirely. Later we can allow a curated subset (pure head-yaw,
        // hand-fidget at hand-only keys) that doesn't conflict.
        if isMocapDriven {
            return
        }

        if gesture.isBaked {
            playBaked(gesture, on: root)
            return
        }

        switch gesture {
        case .nod, .shake, .lookLeft, .lookRight, .headTilt:
            let target = headBone ?? root
            target.removeAction(forKey: headGestureKey)
            target.runAction(proceduralAction(for: gesture), forKey: headGestureKey)

        case .bow:
            let target = spineBone ?? root
            target.removeAction(forKey: headGestureKey)
            target.runAction(proceduralAction(for: gesture), forKey: headGestureKey)

        case .jump, .cheer, .wiggle, .weightShift:
            root.removeAction(forKey: gestureKey)
            root.runAction(proceduralAction(for: gesture), forKey: gestureKey)

        case .armStretch:
            // Both arms rise together then settle. Rotates the upper-arm
            // deform bone so forearm+hand come along for the ride. Skip
            // silently if the rig doesn't expose arm bones — we can't fake
            // this one from the root without looking weird.
            guard let armL = upperArmLBone, let armR = upperArmRBone else { return }
            armL.removeAction(forKey: armLGestureKey)
            armR.removeAction(forKey: armRGestureKey)
            armL.runAction(armStretchAction(rising: true), forKey: armLGestureKey)
            armR.runAction(armStretchAction(rising: true), forKey: armRGestureKey)

        case .handFidget:
            // Tiny alternating wrist twist on both hands. If hand bones
            // aren't found, fall back to shoulders so there's still motion.
            let l = handLBone ?? upperArmLBone
            let r = handRBone ?? upperArmRBone
            l?.removeAction(forKey: armLGestureKey)
            r?.removeAction(forKey: armRGestureKey)
            l?.runAction(handFidgetAction(flipped: false), forKey: armLGestureKey)
            r?.runAction(handFidgetAction(flipped: true), forKey: armRGestureKey)

        case .impatient:
            // Compound: root weight-shift + head shake. Runs on separate
            // keys so both layers play concurrently.
            root.removeAction(forKey: gestureKey)
            root.runAction(proceduralAction(for: .weightShift), forKey: gestureKey)
            let head = headBone ?? root
            head.removeAction(forKey: headGestureKey)
            head.runAction(proceduralAction(for: .shake), forKey: headGestureKey)

        default:
            break  // shouldn't hit — baked cases handled above
        }
    }

    func play(marker: String) {
        guard let g = Gesture.fromMarker(marker) else {
            print("[BuddyGesture] Unknown marker: \(marker)")
            return
        }
        play(g)
    }

    // MARK: - Procedural actions

    private func proceduralAction(for gesture: Gesture) -> SCNAction {
        switch gesture {
        case .nod:
            // Two forward-back pitches, ~7° each.
            let down = SCNAction.rotateBy(x: 0.12, y: 0, z: 0, duration: 0.25)
            let up = SCNAction.rotateBy(x: -0.12, y: 0, z: 0, duration: 0.25)
            down.timingMode = .easeInEaseOut
            up.timingMode = .easeInEaseOut
            return SCNAction.sequence([down, up, down, up])

        case .shake:
            let right = SCNAction.rotateBy(x: 0, y: 0.18, z: 0, duration: 0.2)
            let left = SCNAction.rotateBy(x: 0, y: -0.36, z: 0, duration: 0.3)
            let back = SCNAction.rotateBy(x: 0, y: 0.18, z: 0, duration: 0.2)
            [right, left, back].forEach { $0.timingMode = .easeInEaseOut }
            return SCNAction.sequence([right, left, right, left, back])

        case .jump:
            let jumpAmp = 0.8 * heightScale
            let up = SCNAction.moveBy(x: 0, y: jumpAmp, z: 0, duration: 0.25)
            up.timingMode = .easeOut
            let down = SCNAction.moveBy(x: 0, y: -jumpAmp, z: 0, duration: 0.3)
            down.timingMode = .easeIn
            return SCNAction.sequence([up, down])

        case .cheer:
            let cheerAmp = 1.0 * heightScale
            let up = SCNAction.moveBy(x: 0, y: cheerAmp, z: 0, duration: 0.2)
            let down = SCNAction.moveBy(x: 0, y: -cheerAmp, z: 0, duration: 0.25)
            let scaleUp = SCNAction.scale(by: 1.05, duration: 0.2)
            let scaleDown = SCNAction.scale(by: 1.0 / 1.05, duration: 0.25)
            up.timingMode = .easeOut
            down.timingMode = .easeIn
            let jump1 = SCNAction.group([up, scaleUp])
            let settle1 = SCNAction.group([down, scaleDown])
            return SCNAction.sequence([jump1, settle1, jump1, settle1])

        case .bow:
            let forward = SCNAction.rotateBy(x: 0.35, y: 0, z: 0, duration: 0.5)
            forward.timingMode = .easeOut
            let hold = SCNAction.wait(duration: 0.4)
            let back = SCNAction.rotateBy(x: -0.35, y: 0, z: 0, duration: 0.6)
            back.timingMode = .easeInEaseOut
            return SCNAction.sequence([forward, hold, back])

        case .wiggle:
            let right = SCNAction.rotateBy(x: 0, y: 0, z: 0.15, duration: 0.18)
            let left = SCNAction.rotateBy(x: 0, y: 0, z: -0.3, duration: 0.28)
            let back = SCNAction.rotateBy(x: 0, y: 0, z: 0.15, duration: 0.18)
            [right, left, back].forEach { $0.timingMode = .easeInEaseOut }
            return SCNAction.sequence([right, left, right, left, back])

        case .lookLeft:
            let turn = SCNAction.rotateBy(x: 0, y: 0.35, z: 0, duration: 0.35)
            turn.timingMode = .easeOut
            let hold = SCNAction.wait(duration: 0.9)
            let back = SCNAction.rotateBy(x: 0, y: -0.35, z: 0, duration: 0.45)
            back.timingMode = .easeInEaseOut
            return SCNAction.sequence([turn, hold, back])

        case .lookRight:
            let turn = SCNAction.rotateBy(x: 0, y: -0.35, z: 0, duration: 0.35)
            turn.timingMode = .easeOut
            let hold = SCNAction.wait(duration: 0.9)
            let back = SCNAction.rotateBy(x: 0, y: 0.35, z: 0, duration: 0.45)
            back.timingMode = .easeInEaseOut
            return SCNAction.sequence([turn, hold, back])

        case .headTilt:
            // Tilt head ~10° to the side, hold curiously, return.
            let tilt = SCNAction.rotateBy(x: 0, y: 0, z: 0.18, duration: 0.35)
            tilt.timingMode = .easeOut
            let hold = SCNAction.wait(duration: 0.7)
            let back = SCNAction.rotateBy(x: 0, y: 0, z: -0.18, duration: 0.4)
            back.timingMode = .easeInEaseOut
            return SCNAction.sequence([tilt, hold, back])

        case .weightShift:
            // Bigger one-shot weight shift ~25cm at Micoo scale. Stays
            // within the frame because it returns to zero. Scaled to
            // buddy size so smaller models don't slide off-screen.
            let amp = 0.25 * heightScale
            let out = SCNAction.moveBy(x: amp, y: 0, z: 0, duration: 0.8)
            out.timingMode = .easeInEaseOut
            let hold = SCNAction.wait(duration: 0.6)
            let back = SCNAction.moveBy(x: -amp, y: 0, z: 0, duration: 0.9)
            back.timingMode = .easeInEaseOut
            return SCNAction.sequence([out, hold, back])

        default:
            return SCNAction.wait(duration: 0)
        }
    }

    /// Shoulder rotation that lifts the arm forward ~25° and brings it back.
    /// Used by `armStretch`. Parameter `rising` just toggles the sign so we
    /// could theoretically stretch backwards — keep true in practice.
    private func armStretchAction(rising: Bool) -> SCNAction {
        let sign: Float = rising ? -1 : 1
        let lift = SCNAction.rotateBy(x: CGFloat(sign * 0.45), y: 0, z: 0, duration: 0.55)
        lift.timingMode = .easeOut
        let hold = SCNAction.wait(duration: 0.5)
        let settle = SCNAction.rotateBy(x: CGFloat(-sign * 0.45), y: 0, z: 0, duration: 0.7)
        settle.timingMode = .easeInEaseOut
        return SCNAction.sequence([lift, hold, settle])
    }

    /// Small wrist/hand flick — twist ~15° and back, optionally mirrored.
    private func handFidgetAction(flipped: Bool) -> SCNAction {
        let sign: Float = flipped ? -1 : 1
        let a = SCNAction.rotateBy(x: 0, y: CGFloat(sign * 0.25), z: 0, duration: 0.22)
        a.timingMode = .easeInEaseOut
        let b = SCNAction.rotateBy(x: 0, y: CGFloat(-sign * 0.5), z: 0, duration: 0.32)
        b.timingMode = .easeInEaseOut
        let c = SCNAction.rotateBy(x: 0, y: CGFloat(sign * 0.25), z: 0, duration: 0.22)
        c.timingMode = .easeInEaseOut
        return SCNAction.sequence([a, b, c])
    }

    // MARK: - Baked clips

    /// Loads a baked CAAnimation from `Animations/<buddyId>/<clipName>.usdz`
    /// in the main bundle, caching the result.
    ///
    /// USDZ animations don't show up via `SCNSceneSource.identifiersOfEntries`
    /// — SceneKit attaches them as `SCNAnimationPlayer` instances on nodes in
    /// the scene graph. So we load the scene and walk the hierarchy to
    /// collect every animation, then return the longest (each clip exports
    /// as several per-bone animations; we want the one covering the full
    /// motion, or we just pick the longest and trust SceneKit to include
    /// all tracks in a single CAAnimationGroup).
    private func loadBakedClip(_ clipName: String) -> BakedClip? {
        if let cached = bakedCache[clipName] {
            return cached
        }
        let subdir = "Animations/\(buddyId)"
        guard let url = Bundle.main.url(forResource: clipName, withExtension: "usdz", subdirectory: subdir)
                ?? Bundle.main.url(forResource: clipName, withExtension: "usdz")
        else {
            return nil
        }

        let scene: SCNScene
        do {
            scene = try SCNScene(url: url, options: [
                .animationImportPolicy: SCNSceneSource.AnimationImportPolicy.playRepeatedly
            ])
        } catch {
            return nil
        }

        var collected: [(nodeName: String, animation: SCNAnimation)] = []
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
            // Pipeline not ready — see comment on the Gesture enum's baked cases.
            return nil
        }

        let clip = BakedClip(tracks: collected, duration: maxDuration)
        bakedCache[clipName] = clip
        return clip
    }

    private func playBaked(_ gesture: Gesture, on root: SCNNode) {
        guard let clipName = gesture.bakedClipName,
              let clip = loadBakedClip(clipName)
        else {
            // Baked pipeline not available — fall back to a procedural
            // approximation so LLM-triggered markers don't no-op. Picks
            // the closest-feeling procedural gesture for the request.
            let fallback: Gesture
            switch gesture {
            case .wave, .pointLeft, .pointUp, .pointDown, .awake:
                fallback = .armStretch
            case .yesJump, .cheer:
                fallback = .jump
            case .thinking, .shy, .dontKnow:
                fallback = .headTilt
            case .frustration, .crossedArms:
                fallback = .impatient
            case .blowKiss:
                fallback = .handFidget
            default:
                fallback = .wiggle
            }
            print("[BuddyGesture] Baked \(gesture.rawValue) unavailable, procedural fallback: \(fallback.rawValue)")
            play(fallback)
            return
        }

        // Prevent overlapping baked clips — they all drive the whole skeleton.
        if Date() < bakedPlaybackEndsAt {
            print("[BuddyGesture] Skipping baked \(gesture.rawValue): another clip still playing")
            return
        }

        // Retarget each track onto the matching bone in the live skeleton.
        var attached = 0
        var missing: [String] = []
        for (nodeName, anim) in clip.tracks {
            guard let target = root.childNode(withName: nodeName, recursively: true) else {
                if missing.count < 3 { missing.append(nodeName) }
                continue
            }
            anim.blendInDuration = 0.15
            anim.blendOutDuration = 0.25
            anim.isRemovedOnCompletion = true
            anim.repeatCount = 1
            let key = "\(bakedKey)_\(nodeName)"
            target.removeAnimation(forKey: key, blendOutDuration: 0.1)
            let player = SCNAnimationPlayer(animation: anim)
            player.speed = 1.0
            target.addAnimationPlayer(player, forKey: key)
            player.play()
            attached += 1
        }

        let missingStr = missing.joined(separator: ", ")
        let suffix = missing.isEmpty ? "" : ", missing e.g. \(missingStr)"
        print("[BuddyGesture] Baked \(gesture.rawValue): attached \(attached)/\(clip.tracks.count) tracks\(suffix)")

        bakedPlaybackEndsAt = Date().addingTimeInterval(clip.duration)
    }

    // MARK: - Ambient scheduler

    /// Procedural fidgets the scheduler fires unprompted. Mix of arm
    /// stretches, weight shifts, head tilts — things that make the buddy
    /// look like it's waiting patiently rather than frozen between sentences.
    /// Baked clips are excluded because the current USDZ pipeline doesn't
    /// produce SceneKit-readable animations.
    private let ambientPool: [Gesture] = [
        .armStretch, .weightShift, .headTilt, .handFidget,
        .lookLeft, .lookRight, .impatient,
    ]

    /// Mean interval between ambient gestures. Actual gap is randomized
    /// in `[0.6, 1.4]×` this to avoid a metronomic cadence. Shorter than
    /// the old baked interval because procedural fidgets are subtler.
    private let ambientMeanInterval: TimeInterval = 9.0

    private func startAmbientScheduler() {
        stopAmbientScheduler()
        scheduleNextAmbient()
    }

    private func stopAmbientScheduler() {
        ambientTimer?.invalidate()
        ambientTimer = nil
    }

    private func scheduleNextAmbient() {
        let jitter = Double.random(in: 0.6...1.4)
        let delay = ambientMeanInterval * jitter
        ambientTimer?.invalidate()
        ambientTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fireAmbientTick() }
        }
    }

    private func fireAmbientTick() {
        defer { scheduleNextAmbient() }
        guard !isSpeaking,
              !isMocapDriven,
              buddyNode != nil,
              Date() >= bakedPlaybackEndsAt,
              let gesture = ambientPool.randomElement()
        else { return }
        print("[BuddyGesture] Ambient: \(gesture.rawValue)")
        play(gesture)
    }

    /// Called by ChatViewModel when TTS starts/stops. While speaking,
    /// the ambient scheduler stays quiet so the buddy doesn't wave in
    /// the middle of a sentence — the LLM-driven gesture markers cover
    /// that window instead.
    func setSpeaking(_ speaking: Bool) {
        isSpeaking = speaking
    }
}
