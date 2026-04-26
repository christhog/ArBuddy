//
//  RealityKitBuddyPreviewView.swift
//  ARBuddy
//
//  Created by Codex on 26.04.26.
//

import Combine
import ARKit
import RealityKit
import SwiftUI
import UIKit

struct RealityKitBuddyPreviewView: UIViewRepresentable {
    let modelEntity: Entity?
    let buddy: Buddy?
    var allowsRotation: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        arView.backgroundColor = .black
        arView.isOpaque = true
        arView.environment.background = .color(.black)
        arView.renderOptions.insert(.disableCameraGrain)
        arView.renderOptions.insert(.disableMotionBlur)
        context.coordinator.attach(to: arView, allowsRotation: allowsRotation)
        context.coordinator.update(modelEntity: modelEntity, buddy: buddy)
        return arView
    }

    func updateUIView(_ arView: ARView, context: Context) {
        context.coordinator.update(modelEntity: modelEntity, buddy: buddy)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.releasePreview()
        uiView.session.pause()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var arView: ARView?
        private var anchor: AnchorEntity?
        private var previewRoot: Entity?
        private var currentEntity: Entity?
        private var currentBuddyID: UUID?
        private var currentAnimationController: AnimationPlaybackController?
        private var currentAnimationUsesEmbeddedFaceTimeline = false
        private var aledaAnimationSlices: [AledaARAnimationClip: AnimationResource] = [:]
        private var cancellables = Set<AnyCancellable>()
        private var panStartAngle: Float = 0
        private var currentAngle: Float = 0
        private var basePreviewScale: Float = 1
        private var currentZoom: Float = 1
        private var pinchStartZoom: Float = 1
        private var basePreviewPosition = SIMD3<Float>(repeating: 0)
        private var baseScaledCenter = SIMD3<Float>(repeating: 0)
        private var currentPanOffset = SIMD3<Float>(repeating: 0)
        private var panStartOffset = SIMD3<Float>(repeating: 0)
        private var azureSpeechActive = false
        private var azureSpeechLoading = false
        private var localSpeechActive = false
        private var lipSyncActive = false
        private var idleResumeWorkItem: DispatchWorkItem?

        private var speechOrTTSBusy: Bool {
            azureSpeechActive || azureSpeechLoading || localSpeechActive || lipSyncActive
        }

        private struct AledaTimelineSlice {
            let startFrame: Double
            let endFrame: Double
            let fps: Double
            let speed: Float

            var startTime: TimeInterval {
                (startFrame - 1) / fps
            }

            var endTime: TimeInterval {
                endFrame / fps
            }
        }

        private let aledaTimelineSlices: [AledaARAnimationClip: AledaTimelineSlice] = [
            .idle: AledaTimelineSlice(startFrame: 1, endFrame: 301, fps: 30, speed: 1.0),
            .walking: AledaTimelineSlice(startFrame: 330, endFrame: 371, fps: 30, speed: 0.78)
        ]

        func attach(to arView: ARView, allowsRotation: Bool) {
            guard self.arView !== arView else { return }
            self.arView = arView

            let anchor = AnchorEntity(world: .zero)
            self.anchor = anchor
            arView.scene.addAnchor(anchor)
            configureCameraAndLights(on: anchor)

            AzureSpeechService.shared.$isSpeaking
                .receive(on: DispatchQueue.main)
                .sink { [weak self] speaking in
                    guard let self else { return }
                    self.azureSpeechActive = speaking
                    self.handleSpeechStateChanged()
                }
                .store(in: &cancellables)

            AzureSpeechService.shared.$isLoading
                .receive(on: DispatchQueue.main)
                .sink { [weak self] loading in
                    guard let self else { return }
                    self.azureSpeechLoading = loading
                    self.handleSpeechStateChanged()
                }
                .store(in: &cancellables)

            TextToSpeechService.shared.$state
                .map { $0.isSpeaking }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] speaking in
                    guard let self else { return }
                    self.localSpeechActive = speaking
                    self.handleSpeechStateChanged()
                }
                .store(in: &cancellables)

            LipSyncService.shared.$state
                .map { $0.isActive }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] active in
                    guard let self else { return }
                    self.lipSyncActive = active
                    self.handleSpeechStateChanged()
                }
                .store(in: &cancellables)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            arView.addGestureRecognizer(pinch)

            let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
            twoFingerPan.minimumNumberOfTouches = 2
            twoFingerPan.maximumNumberOfTouches = 2
            twoFingerPan.delegate = self
            arView.addGestureRecognizer(twoFingerPan)

            guard allowsRotation else { return }
            let rotationPan = UIPanGestureRecognizer(target: self, action: #selector(handleRotationPan(_:)))
            rotationPan.minimumNumberOfTouches = 1
            rotationPan.maximumNumberOfTouches = 1
            rotationPan.delegate = self
            arView.addGestureRecognizer(rotationPan)
        }

        func update(modelEntity: Entity?, buddy: Buddy?) {
            guard let source = modelEntity else {
                clearCurrentEntity()
                return
            }

            if currentEntity != nil, currentBuddyID == buddy?.id {
                return
            }

            clearCurrentEntity()

            let clone = source.clone(recursive: true)
            clone.name = buddy?.name ?? source.name

            let root = Entity()
            root.name = "RealityKitBuddyPreviewRoot"
            root.addChild(clone)

            anchor?.addChild(root)
            previewRoot = root
            currentEntity = clone
            currentBuddyID = buddy?.id
            currentAngle = 0
            currentZoom = 1
            currentPanOffset = SIMD3<Float>(repeating: 0)

            frameEntity(root)
            configureLipSync(for: clone)

            if isAleda(buddy), !speechOrTTSBusy {
                scheduleIdleResume(on: clone, delay: 2.0)
            }

            print("[RealityKitPreview] Loaded buddy preview: \(buddy?.name ?? clone.name)")
        }

        func releasePreview() {
            idleResumeWorkItem?.cancel()
            idleResumeWorkItem = nil
            currentAnimationController?.stop()
            currentAnimationController = nil
            currentAnimationUsesEmbeddedFaceTimeline = false
            LipSyncService.shared.stopAnimation()
            if let anchor, let arView {
                arView.scene.removeAnchor(anchor)
            }
            anchor = nil
            arView = nil
            currentEntity = nil
            previewRoot = nil
            cancellables.removeAll()
        }

        private func clearCurrentEntity() {
            idleResumeWorkItem?.cancel()
            idleResumeWorkItem = nil
            currentAnimationController?.stop()
            currentAnimationController = nil
            currentAnimationUsesEmbeddedFaceTimeline = false
            previewRoot?.removeFromParent()
            previewRoot = nil
            currentEntity = nil
            currentBuddyID = nil
            resetPreviewTransformState()
        }

        private func configureCameraAndLights(on anchor: AnchorEntity) {
            let camera = PerspectiveCamera()
            camera.name = "RealityKitPreviewCamera"
            camera.camera.fieldOfViewInDegrees = 34
            camera.position = SIMD3<Float>(0, 0.62, 1.35)
            camera.look(at: SIMD3<Float>(0, 0.45, 0), from: camera.position, relativeTo: anchor)
            anchor.addChild(camera)

            let keyLight = DirectionalLight()
            keyLight.name = "RealityKitPreviewKeyLight"
            keyLight.light.intensity = 9000
            keyLight.orientation = simd_quatf(angle: -.pi / 4, axis: SIMD3<Float>(1, 0, 0))
                * simd_quatf(angle: .pi / 5, axis: SIMD3<Float>(0, 1, 0))
            anchor.addChild(keyLight)

            let fillLight = PointLight()
            fillLight.name = "RealityKitPreviewFillLight"
            fillLight.light.intensity = 450
            fillLight.position = SIMD3<Float>(-0.45, 0.75, 0.75)
            anchor.addChild(fillLight)
        }

        private func frameEntity(_ root: Entity) {
            guard let arView else { return }

            let bounds = root.visualBounds(relativeTo: nil)
            let extents = bounds.extents
            let center = bounds.center
            let maxExtent = max(extents.x, max(extents.y, extents.z))
            guard maxExtent > 0 else { return }

            let targetHeight: Float = 0.72
            let scale = targetHeight / max(extents.y, 0.001)
            basePreviewScale = scale
            currentZoom = 1

            let scaledCenter = center * scale
            baseScaledCenter = scaledCenter
            basePreviewPosition = SIMD3<Float>(-scaledCenter.x, -scaledCenter.y + targetHeight * 0.48, -scaledCenter.z)
            currentPanOffset = SIMD3<Float>(repeating: 0)
            applyPreviewTransform()

            if let camera = anchor?.children.first(where: { $0.name == "RealityKitPreviewCamera" }) {
                let aspect = Float(max(arView.bounds.width, 1) / max(arView.bounds.height, 1))
                let distance = max(1.05, targetHeight * (aspect < 0.75 ? 1.85 : 1.45))
                let lookAt = SIMD3<Float>(0, targetHeight * 0.52, 0)
                camera.position = SIMD3<Float>(0, targetHeight * 0.58, distance)
                camera.look(at: lookAt, from: camera.position, relativeTo: anchor)
            }
        }

        private func configureLipSync(for entity: Entity) {
            Task { @MainActor in
                let capabilities = await LipSyncService.shared.inspectModel(entity)
                LipSyncService.shared.configure(for: entity, capabilities: capabilities)
                print("[RealityKitPreview] Lip sync configured: \(capabilities.recommendedLipSyncMode.displayName)")
            }
        }

        private func handleSpeechStateChanged() {
            guard let entity = currentEntity else { return }

            if speechOrTTSBusy {
                idleResumeWorkItem?.cancel()
                idleResumeWorkItem = nil
                if currentAnimationUsesEmbeddedFaceTimeline {
                    currentAnimationController?.stop()
                    currentAnimationController = nil
                    currentAnimationUsesEmbeddedFaceTimeline = false
                }
            } else if isAledaName(entity.name) {
                scheduleIdleResume(on: entity, delay: 0.8)
            }
        }

        private func scheduleIdleResume(on entity: Entity, delay: TimeInterval) {
            idleResumeWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self, weak entity] in
                guard let self,
                      let entity,
                      !self.speechOrTTSBusy,
                      self.currentEntity === entity else {
                    return
                }
                self.playAledaAnimation(.idle, on: entity)
            }

            idleResumeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        @objc
        private func handleRotationPan(_ gesture: UIPanGestureRecognizer) {
            guard let arView, previewRoot != nil else { return }

            switch gesture.state {
            case .began:
                panStartAngle = currentAngle
            case .changed:
                let translation = gesture.translation(in: arView)
                currentAngle = panStartAngle + Float(translation.x) * 0.008
                applyPreviewTransform()
            default:
                break
            }
        }

        @objc
        private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard previewRoot != nil else { return }

            switch gesture.state {
            case .began:
                pinchStartZoom = currentZoom
            case .changed:
                currentZoom = clamp(pinchStartZoom * Float(gesture.scale), min: 0.65, max: 3.0)
                applyPreviewTransform()
            default:
                break
            }
        }

        @objc
        private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
            guard let arView, previewRoot != nil else { return }

            switch gesture.state {
            case .began:
                panStartOffset = currentPanOffset
            case .changed:
                let translation = gesture.translation(in: arView)
                let zoomDamping = min(max(currentZoom, 0.8), 1.8)
                let pointsToWorld = 0.0014 / zoomDamping
                let extraZoom = max(currentZoom - 1, 0)
                let xLimit = 0.42 + extraZoom * 0.22
                let minY = -0.32 - extraZoom * 0.35
                let maxY = 0.46 + extraZoom * 0.45
                var offset = panStartOffset
                offset.x += Float(translation.x) * pointsToWorld
                offset.y -= Float(translation.y) * pointsToWorld
                offset.x = clamp(offset.x, min: -xLimit, max: xLimit)
                offset.y = clamp(offset.y, min: minY, max: maxY)
                currentPanOffset = offset
                applyPreviewTransform()
            default:
                break
            }
        }

        private func applyPreviewTransform() {
            guard let previewRoot else { return }
            previewRoot.scale = SIMD3<Float>(repeating: basePreviewScale * currentZoom)
            previewRoot.position = basePreviewPosition - (baseScaledCenter * (currentZoom - 1)) + currentPanOffset
            previewRoot.orientation = simd_quatf(angle: currentAngle, axis: SIMD3<Float>(0, 1, 0))
        }

        private func resetPreviewTransformState() {
            basePreviewScale = 1
            currentZoom = 1
            pinchStartZoom = 1
            basePreviewPosition = SIMD3<Float>(repeating: 0)
            baseScaledCenter = SIMD3<Float>(repeating: 0)
            currentPanOffset = SIMD3<Float>(repeating: 0)
            panStartOffset = SIMD3<Float>(repeating: 0)
            panStartAngle = 0
            currentAngle = 0
        }

        private func clamp(_ value: Float, min minValue: Float, max maxValue: Float) -> Float {
            Swift.max(minValue, Swift.min(maxValue, value))
        }

        @discardableResult
        private func playAledaAnimation(_ clip: AledaARAnimationClip, on entity: Entity) -> Bool {
            if clip == .idle {
                if BuddyMocapService.shared.play(.default, on: entity, loop: true) {
                    currentAnimationController?.stop()
                    currentAnimationController = nil
                    currentAnimationUsesEmbeddedFaceTimeline = false
                    print("[RealityKitPreview] Playing Aleda body-only mocap \(MocapClip.default.rawValue) on '\(entity.name)'")
                    return true
                }

                print("[RealityKitPreview] Aleda body-only mocap \(MocapClip.default.rawValue) did not start; not falling back to embedded face timeline")
                return false
            }

            guard let (animatedEntity, animations) = firstEntityWithEmbeddedAnimations(in: entity),
                  let fullTimeline = animations.first else {
                print("[RealityKitPreview] Aleda \(clip.rawValue) animation unavailable: no embedded RealityKit timeline")
                return false
            }

            guard let animation = makeAledaTimelineAnimation(clip, from: fullTimeline) else {
                return false
            }

            currentAnimationController?.stop()
            currentAnimationController = animatedEntity.playAnimation(
                animation.repeat(),
                transitionDuration: 0.35,
                startsPaused: false
            )
            currentAnimationUsesEmbeddedFaceTimeline = true
            print("[RealityKitPreview] Playing Aleda \(clip.rawValue) animation on '\(animatedEntity.name)'")
            return true
        }

        private func makeAledaTimelineAnimation(_ clip: AledaARAnimationClip, from fullTimeline: AnimationResource) -> AnimationResource? {
            if let cachedAnimation = aledaAnimationSlices[clip] {
                return cachedAnimation
            }

            guard let slice = aledaTimelineSlices[clip] else {
                print("[RealityKitPreview] Missing Aleda timeline metadata for \(clip.rawValue)")
                return nil
            }

            let animationView = AnimationView(
                source: fullTimeline.definition,
                name: "Preview_Aleda_\(clip.rawValue)",
                bindTarget: nil,
                blendLayer: 0,
                repeatMode: .none,
                fillMode: [],
                trimStart: slice.startTime,
                trimEnd: slice.endTime,
                trimDuration: nil,
                offset: 0,
                delay: 0,
                speed: slice.speed
            )

            do {
                let animation = try AnimationResource.generate(with: animationView)
                aledaAnimationSlices[clip] = animation
                print("[RealityKitPreview] Generated Aleda \(clip.rawValue) slice frames=\(Int(slice.startFrame))...\(Int(slice.endFrame))")
                return animation
            } catch {
                print("[RealityKitPreview] Failed to generate Aleda \(clip.rawValue) slice: \(error.localizedDescription)")
                return nil
            }
        }

        private func firstEntityWithEmbeddedAnimations(in entity: Entity) -> (Entity, [AnimationResource])? {
            if !entity.availableAnimations.isEmpty {
                return (entity, entity.availableAnimations)
            }

            for child in entity.children {
                if let match = firstEntityWithEmbeddedAnimations(in: child) {
                    return match
                }
            }

            return nil
        }

        private func isAleda(_ buddy: Buddy?) -> Bool {
            isAledaName(buddy?.name ?? "")
        }

        private func isAledaName(_ name: String) -> Bool {
            name.localizedCaseInsensitiveContains("Aleda")
        }

        nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
