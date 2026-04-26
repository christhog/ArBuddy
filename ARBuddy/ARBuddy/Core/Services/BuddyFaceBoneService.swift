//
//  BuddyFaceBoneService.swift
//  ARBuddy
//
//  Bone-driven eye + lid animation for DAZ Genesis 9 rigs. On G9, eye skin
//  bindings survive the Blender USD export cleanly, so eye pitch/yaw and lid
//  rotation deform the mesh as expected. The service only activates when the
//  expected G9 face bones are present (l_eye/r_eye/l_eyelidupper/…), so it
//  stays inert on Micoo and other morph-rigged buddies.
//
//  Scope: idle blinks + saccades + directed gaze (lookAtCamera). Mouth/jaw/
//  brow/cheek animation lives on the morph-target path (FacialExpressionService
//  + SceneKitLipSyncService.morphTargets mode) because the G9 mouth submesh
//  has no usable bone skin weights after USD export.
//

import Foundation
import SceneKit

@MainActor
final class BuddyFaceBoneService {
    static let shared = BuddyFaceBoneService()

    private init() {}

    // MARK: - Bone Refs

    private weak var leftEye: SCNNode?
    private weak var rightEye: SCNNode?
    private weak var leftLidUpper: SCNNode?
    private weak var leftLidLower: SCNNode?
    private weak var rightLidUpper: SCNNode?
    private weak var rightLidLower: SCNNode?

    /// Rest-pose eulerAngles snapshot keyed by ObjectIdentifier. DAZ G9 face
    /// bones do NOT sit at (0,0,0) in rest — capturing the baseline once lets
    /// every action run as an additive offset and snap cleanly back.
    private var restEuler: [ObjectIdentifier: SCNVector3] = [:]

    // MARK: - Idle State

    private var idleRunning = false
    private var blinkTimer: Timer?
    private var saccadeTimer: Timer?

    // MARK: - Tunables

    /// Upper-lid pitch (radians) when fully closed. ~34°. Adjust sign if the
    /// lid rotates outward/backward instead of closing.
    private let blinkUpperAmplitude: CGFloat = 0.6
    /// Lower-lid pitch counter-rotation. Lower lid barely moves on real faces,
    /// just enough to meet the upper lid.
    private let blinkLowerAmplitude: CGFloat = 0.15

    /// Eye-bone yaw/pitch for saccades. ~13° — the earlier 7° value read as
    /// a twitch rather than a glance. Still small enough to feel involuntary,
    /// not a deliberate stare.
    private let saccadeAmplitude: Float = 0.22
    /// How long the eyes rest in the saccade pose before drifting back.
    /// Longer hold = less twitchy, more like natural glances.
    private let saccadeHoldDuration: TimeInterval = 0.8
    /// Ease-in duration for the saccade itself. 100 ms is near-instant;
    /// 150 ms still reads as fast but looks less like a jolt.
    private let saccadeMoveDuration: TimeInterval = 0.15

    // MARK: - Configure

    func configure(buddyNode: SCNNode) {
        clear()

        buddyNode.enumerateHierarchy { node, _ in
            guard let name = node.name else { return }
            switch name {
            case "l_eye":          self.leftEye = node
            case "r_eye":          self.rightEye = node
            case "l_eyelidupper":  self.leftLidUpper = node
            case "l_eyelidlower":  self.leftLidLower = node
            case "r_eyelidupper":  self.rightLidUpper = node
            case "r_eyelidlower":  self.rightLidLower = node
            default:               break
            }
        }

        // Activation guard: need at least the eye + upper-lid pair on both
        // sides, otherwise this rig isn't a G9-style face and the service
        // should stay silent.
        guard leftEye != nil, rightEye != nil,
              leftLidUpper != nil, rightLidUpper != nil else {
            print("[FaceBone] No G9 face bones found — service idle")
            clear()
            return
        }

        let bones: [SCNNode?] = [
            leftEye, rightEye,
            leftLidUpper, leftLidLower,
            rightLidUpper, rightLidLower
        ]
        for bone in bones.compactMap({ $0 }) {
            restEuler[ObjectIdentifier(bone)] = bone.eulerAngles
        }

        print("[FaceBone] Configured G9 face rig — eyes + lids")
    }

    func clear() {
        stopIdleBehaviors()
        leftEye = nil
        rightEye = nil
        leftLidUpper = nil
        leftLidLower = nil
        rightLidUpper = nil
        rightLidLower = nil
        restEuler.removeAll()
    }

    // MARK: - Idle Control

    func startIdleBehaviors() {
        guard leftEye != nil else { return }  // service inactive on this rig
        idleRunning = true
        scheduleNextBlink()
        scheduleNextSaccade()
    }

    func stopIdleBehaviors() {
        idleRunning = false
        blinkTimer?.invalidate()
        blinkTimer = nil
        saccadeTimer?.invalidate()
        saccadeTimer = nil
    }

    // MARK: - Blink

    private func scheduleNextBlink() {
        // ~10 % chance of a quick double-blink, otherwise 3–6 s pause.
        let delay = Double.random(in: 0...1) < 0.10
            ? 0.35
            : Double.random(in: 3.0...6.0)
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fireBlink() }
        }
    }

    private func fireBlink() {
        defer { scheduleNextBlink() }
        guard idleRunning else { return }

        let closeUpper = SCNAction.rotateBy(x: blinkUpperAmplitude, y: 0, z: 0, duration: 0.08)
        let hold = SCNAction.wait(duration: 0.04)
        let blinkUpper = SCNAction.sequence([closeUpper, hold, closeUpper.reversed()])

        let closeLower = SCNAction.rotateBy(x: -blinkLowerAmplitude, y: 0, z: 0, duration: 0.08)
        let blinkLower = SCNAction.sequence([closeLower, hold, closeLower.reversed()])

        leftLidUpper?.runAction(blinkUpper)
        rightLidUpper?.runAction(blinkUpper)
        leftLidLower?.runAction(blinkLower)
        rightLidLower?.runAction(blinkLower)
    }

    // MARK: - Saccades

    private func scheduleNextSaccade(after delay: TimeInterval? = nil) {
        // Default range 3–7 s. Longer than the old 2–5 s because each
        // saccade now holds 0.8 s, so we give the eyes time to rest at
        // the new target before picking another one.
        let wait = delay ?? Double.random(in: 3.0...7.0)
        saccadeTimer?.invalidate()
        saccadeTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fireSaccade() }
        }
    }

    private func fireSaccade() {
        defer { scheduleNextSaccade() }
        guard idleRunning else { return }

        // x = pitch (look up/down), y = yaw (look left/right).
        let (dx, dy): (CGFloat, CGFloat) = {
            switch Int.random(in: 0..<4) {
            case 0: return (0,  CGFloat(saccadeAmplitude))   // look right
            case 1: return (0, -CGFloat(saccadeAmplitude))   // look left
            case 2: return (-CGFloat(saccadeAmplitude), 0)   // look up
            default: return (CGFloat(saccadeAmplitude), 0)   // look down
            }
        }()

        let look = SCNAction.rotateBy(x: dx, y: dy, z: 0, duration: saccadeMoveDuration)
        let hold = SCNAction.wait(duration: saccadeHoldDuration)
        let saccade = SCNAction.sequence([look, hold, look.reversed()])

        leftEye?.runAction(saccade)
        rightEye?.runAction(saccade)
    }

    // MARK: - Directed Gaze

    /// Snaps the eyes to their DAZ rest pose and holds them there for `hold`
    /// seconds. In the preview setup the camera sits directly in front of the
    /// buddy, so the rest pose reads as "looking into the camera". The idle
    /// saccade scheduler is suspended for the hold window and resumes
    /// afterwards, so this cleanly interrupts whatever glance was in flight.
    ///
    /// If the camera is off-axis (AR, rotated buddy) this will still point at
    /// the rig-forward direction, not the actual camera position — that case
    /// needs per-frame yaw/pitch computation against `pointOfView.worldPosition`
    /// and is deferred until gaze targeting is wired into the AR pipeline.
    func lookAtCamera(hold: TimeInterval = 2.0) {
        guard leftEye != nil else { return }

        leftEye?.removeAllActions()
        rightEye?.removeAllActions()
        snapEyesToRestPose()

        // Pause saccades for the hold window, then let the normal scheduler
        // pick up again.
        saccadeTimer?.invalidate()
        saccadeTimer = Timer.scheduledTimer(withTimeInterval: hold, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.scheduleNextSaccade() }
        }
    }

    private func snapEyesToRestPose() {
        if let le = leftEye, let rest = restEuler[ObjectIdentifier(le)] {
            le.eulerAngles = rest
        }
        if let re = rightEye, let rest = restEuler[ObjectIdentifier(re)] {
            re.eulerAngles = rest
        }
    }
}
