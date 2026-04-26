//
//  BuddyPreviewView.swift
//  ARBuddy
//
//  Created by Chris Greve on 12.04.26.
//

import SwiftUI
import SceneKit
import RealityKit

/// A view that displays the 3D buddy model without AR, using SceneKit
struct BuddyPreviewView: UIViewRepresentable {
    let modelEntity: ModelEntity?
    var backgroundColor: UIColor = .clear
    var allowsRotation: Bool = true

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView(frame: .zero)
        scnView.backgroundColor = backgroundColor
        scnView.autoenablesDefaultLighting = true
        scnView.allowsCameraControl = false // We handle gestures ourselves
        scnView.antialiasingMode = .multisampling4X

        // Create scene
        let scene = SCNScene()
        scnView.scene = scene

        // Add camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 50
        // Default zNear is 1.0 m — too far for sub-meter models. Anything
        // closer is clipped out and the view goes white.
        cameraNode.camera?.zNear = 0.05
        cameraNode.camera?.zFar = 100
        cameraNode.name = "camera"
        scene.rootNode.addChildNode(cameraNode)
        context.coordinator.cameraNode = cameraNode

        // Add ambient light
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 500
        ambientLight.light?.color = UIColor.white
        scene.rootNode.addChildNode(ambientLight)

        // Add directional light
        let directionalLight = SCNNode()
        directionalLight.light = SCNLight()
        directionalLight.light?.type = .directional
        directionalLight.light?.intensity = 800
        directionalLight.light?.color = UIColor.white
        directionalLight.position = SCNVector3(x: 5, y: 10, z: 10)
        directionalLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(directionalLight)

        // Add gestures
        if allowsRotation {
            let panGesture = UIPanGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handlePan(_:))
            )
            scnView.addGestureRecognizer(panGesture)
        }

        let pinchGesture = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        scnView.addGestureRecognizer(pinchGesture)

        let twoFingerPanGesture = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTwoFingerPan(_:))
        )
        twoFingerPanGesture.minimumNumberOfTouches = 2
        twoFingerPanGesture.maximumNumberOfTouches = 2
        scnView.addGestureRecognizer(twoFingerPanGesture)

        let doubleTapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTapGesture.numberOfTapsRequired = 2
        scnView.addGestureRecognizer(doubleTapGesture)

        context.coordinator.scnView = scnView
        context.coordinator.startObservingARLifecycle()

        // Load model if available
        if modelEntity != nil {
            loadModel(in: scnView, context: context)
        }

        return scnView
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        // Update model if changed
        if let newEntity = modelEntity,
           context.coordinator.currentModelId != ObjectIdentifier(newEntity) {
            loadModel(in: scnView, context: context)
        }
    }

    private func loadModel(in scnView: SCNView, context: Context) {
        guard let entity = modelEntity,
              let scene = scnView.scene else { return }

        // Full teardown of the outgoing buddy before we even start parsing the
        // new USDZ. Without this the old skeleton, its GPU textures and the
        // cached mocap SCNAnimations coexist with the incoming ones during the
        // parse window, driving the memory peak >1 GB on larger assets (Aleda
        // ≈51 MB USDZ with 4K body textures).
        let oldNode = context.coordinator.buddyNode
        BuddyMocapService.shared.stopAndFlush(on: oldNode)
        BuddyGestureService.shared.stopIdle()
        FacialExpressionService.shared.stopIdleBehaviors()
        BuddyFaceBoneService.shared.clear()
        oldNode?.removeFromParentNode()
        scene.rootNode.childNode(withName: "buddy", recursively: false)?.removeFromParentNode()
        context.coordinator.buddyNode = nil

        Task {
            await loadUSDZModel(in: scnView, context: context)
        }

        context.coordinator.currentModelId = ObjectIdentifier(entity)
    }

    @MainActor
    private func loadUSDZModel(in scnView: SCNView, context: Context) async {
        guard let scene = scnView.scene else { return }

        // Try to get buddy from SupabaseService or UserDefaults
        let selectedBuddyId = UserDefaults.standard.string(forKey: "selectedBuddyId")

        var buddyToLoad: Buddy?

        if let selectedId = selectedBuddyId,
           let uuid = UUID(uuidString: selectedId) {
            // Try to find in available buddies
            buddyToLoad = SupabaseService.shared.availableBuddies.first { $0.id == uuid }
        }

        if buddyToLoad == nil {
            buddyToLoad = SupabaseService.shared.selectedBuddy
        }

        // Device-scoped guardrail — forces Micoo on <6 GB devices even if
        // UserDefaults has Aleda cached from a previous run on a beefier
        // device logged in with the same account.
        buddyToLoad = SupabaseService.shared.applyLowMemoryGuardrail(to: buddyToLoad)

        guard let buddy = buddyToLoad else {
            print("No buddy to load for SceneKit preview")
            return
        }

        // Get cached model URL
        let localURL = await BuddyAssetService.shared.localModelURL(for: buddy)

        // Check if file exists, if not try to load from bundle
        var modelURL: URL? = nil

        if FileManager.default.fileExists(atPath: localURL.path) {
            modelURL = localURL
        } else {
            // Try bundle
            let bundleOptions = [
                (buddy.name, "usdz"),
                (buddy.name.lowercased(), "usdz"),
                ("Jona", "usdz")
            ]
            for option in bundleOptions {
                if let url = Bundle.main.url(forResource: option.0, withExtension: option.1) {
                    modelURL = url
                    break
                }
            }
        }

        guard let url = modelURL else {
            print("Could not find model file for buddy: \(buddy.name)")
            return
        }

        do {
            // Parse the USDZ and transplant the meaningful nodes inside an
            // autoreleasepool so the source `SCNScene` and any Foundation
            // temporaries it holds are released before we touch the live
            // scene. Important for large buddies (Aleda ≈51 MB with 4K body
            // textures) where the parse-time peak is the dominant footprint.
            let (buddyNode, hasEmbeddedCamera): (SCNNode, Bool) = try autoreleasepool {
                let modelScene = try SCNScene(url: url, options: [
                    .checkConsistency: true,
                    .flattenScene: false
                ])

                let node = SCNNode()
                node.name = "buddy"

                var embeddedCamera = false
                func checkForCamera(_ n: SCNNode) {
                    let name = n.name?.lowercased() ?? ""
                    if name.contains("camera") {
                        embeddedCamera = true
                        return
                    }
                    for child in n.childNodes {
                        checkForCamera(child)
                        if embeddedCamera { return }
                    }
                }
                checkForCamera(modelScene.rootNode)

                // Move nodes from model scene — direct move (not clone) preserves
                // SCNSkinner.skeleton references; cloning leaves them pointing at
                // nodes in the now-released modelScene, breaking GPU skinning.
                func addFilteredChildren(from source: SCNNode, to target: SCNNode) {
                    let children = source.childNodes  // snapshot before mutation
                    for child in children {
                        let name = child.name?.lowercased() ?? ""
                        if name.contains("camera") ||
                           name.contains("light") ||
                           name.contains("env_") ||
                           name == "_materials" {
                            continue
                        }
                        child.removeFromParentNode()
                        child.childNodes
                            .filter { n in
                                let s = n.name?.lowercased() ?? ""
                                return s.contains("camera") || s.contains("light") || s.contains("env_")
                            }
                            .forEach { $0.removeFromParentNode() }
                        target.addChildNode(child)
                    }
                }
                addFilteredChildren(from: modelScene.rootNode, to: node)

                return (node, embeddedCamera)
            }

            // DAZ Genesis9 exports have 52 ARKit blend shapes. Combined with
            // 144-bone skinning this exceeds Metal's ~22 available vertex-buffer
            // slots for morph data, causing a fatal shader compilation error that
            // makes the body mesh invisible. Trim to the shapes needed for
            // lip-sync and expressions.
            reduceMorphTargets(for: buddyNode, buddyName: buddy.name)

            // Apply scale from buddy config
            let scale = buddy.scale
            buddyNode.scale = SCNVector3(scale, scale, scale)

            // Fix rotation for models with embedded cameras (like Micoo)
            if hasEmbeddedCamera {
                buddyNode.eulerAngles.x = -.pi / 2
                print("Applied rotation fix for model with embedded camera: \(buddy.name)")
            }

            // Add to scene FIRST — USDZ geometry is lazy-loaded, so boundingBox
            // returns zeros until after the first render frame.
            scene.rootNode.addChildNode(buddyNode)
            context.coordinator.buddyNode = buddyNode

            #if DEBUG
            scnView.debugOptions = []
            #endif

            // Wait for SceneKit to initialise geometry, then position the node
            // and camera based on the bounding box. USDZ geometry is lazy-loaded,
            // so complex models (e.g. Genesis 9 with 6 mesh objects + skinning)
            // may need several frames before the bounding box is valid.
            // We retry up to 4 times with increasing delays until the computed
            // visual height looks plausible (> 0.3 m at world scale).
            let cameraNode = context.coordinator.cameraNode
            let coordinator = context.coordinator
            let retryDelays: [Double] = [0.1, 0.3, 0.5, 1.0]

            func positionCamera(attemptIndex: Int) {
                let delay = retryDelays[min(attemptIndex, retryDelays.count - 1)]
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    let (minBound, maxBound) = buddyNode.boundingBox
                    let yExtent = (maxBound.y - minBound.y) * scale
                    let zExtent = (maxBound.z - minBound.z) * scale

                    // Determine which axis holds the model's visual height.
                    // Micoo: embedded camera → height always in Z.
                    // Blender Z-up exports: SceneKit doesn't apply the root's
                    // xformOp:rotateXYZ(-90,0,0), so height is still in Z
                    // (zExtent >> yExtent). Apply -90° X to buddyNode to stand
                    // the model upright, then use Z for camera math.
                    let visualHeight: Float
                    let groundOffset: Float

                    if hasEmbeddedCamera {
                        visualHeight = zExtent
                        groundOffset = -minBound.z * scale
                    } else if zExtent > yExtent * 3.0 {
                        // Blender Z-up: apply rotation once then use Z
                        if abs(buddyNode.eulerAngles.x) < 0.1 {
                            buddyNode.eulerAngles.x = -.pi / 2
                            print("[BuddyPreview] Applied -90° X for Blender Z-up model: \(buddy.name)")
                        }
                        visualHeight = zExtent
                        groundOffset = -minBound.z * scale
                    } else {
                        visualHeight = yExtent
                        groundOffset = -minBound.y * scale
                    }

                    // Retry if the bounding box hasn't been populated yet.
                    let nextAttempt = attemptIndex + 1
                    if visualHeight < 0.3 && nextAttempt < retryDelays.count {
                        print("[BuddyPreview] visH too small (\(visualHeight)), retrying (attempt \(nextAttempt))…")
                        positionCamera(attemptIndex: nextAttempt)
                        return
                    }

                    buddyNode.position = SCNVector3(0, groundOffset, 0)
                    coordinator.saveOriginalTransform(buddyNode)

                    let faceY      = visualHeight * 0.85
                    let fovRadians = Float(50 * Double.pi / 180)
                    // Frame based on height only — T-pose arm span inflates width
                    // and would push the camera too far back.
                    let frameDim   = visualHeight * 0.38
                    let distance   = (frameDim / 2) / tan(fovRadians / 2)

                    let camY   = faceY * 1.15
                    let lookAt = faceY * 0.88
                    cameraNode?.position = SCNVector3(0, camY, distance)
                    cameraNode?.look(at: SCNVector3(0, lookAt, 0))

                    // Now that the real world-space height is known, scale
                    // idle amplitudes accordingly and (re)start the idle
                    // layers so they don't use the default Micoo-sized
                    // translations on smaller buddies like Aleda.
                    BuddyGestureService.shared.updateWorldHeight(CGFloat(visualHeight))
                    BuddyGestureService.shared.startIdle()

                    print("[BuddyPreview] camY=\(camY) faceY=\(faceY) dist=\(distance) visH=\(visualHeight) attempt=\(attemptIndex)")
                }
            }

            positionCamera(attemptIndex: 0)

            // Aleda's app USDZ is now a RealityKit timeline bank. In SceneKit
            // those embedded timeline tracks include morpher-weight animation
            // that fights the preview lip-sync service every frame. Keep the
            // preview's face morphers free and let the SceneKit services drive
            // idle/lip/expression motion instead.
            if buddy.name.caseInsensitiveCompare("Aleda") == .orderedSame {
                stopEmbeddedAnimations(for: buddyNode)
                print("[BuddyPreview] Skipped embedded Aleda timeline in SceneKit preview")
            } else {
                playAnimations(for: buddyNode)
            }

            // Configure SceneKit lip sync service
            SceneKitLipSyncService.shared.configure(buddyNode: buddyNode)

            // Configure facial expression layer (eye blinks, brow raises, emotions)
            FacialExpressionService.shared.configure(buddyNode: buddyNode)
            FacialExpressionService.shared.startIdleBehaviors()

            // Bone-driven face layer for rigs without blendshapes (DAZ G9 → Aleda).
            // Stays inert on morph-rigged buddies like Micoo.
            BuddyFaceBoneService.shared.configure(buddyNode: buddyNode)
            BuddyFaceBoneService.shared.startIdleBehaviors()

            // Apply persisted skin tint (if any). Registers this node as the
            // active target so the Settings picker can live-refresh.
            BuddyTintService.shared.apply(
                tint: BuddyTintService.shared.loadPersistedTint(for: buddy.name),
                to: buddyNode,
                buddyId: buddy.name
            )

            // Force lashes (and other DAZ materials that lost their base-color
            // tint during USDZ export) back to black. No-op for buddies that
            // aren't in the per-buddy table.
            BuddyEyeMakeupService.shared.apply(to: buddyNode, buddyId: buddy.name)

            // Procedural idle (breathing + micro-sway) and gesture dispatch.
            // Idle itself is started from inside positionCamera's callback
            // once the real world-space height is known, so the amplitudes
            // are scaled to the actual buddy size.
            BuddyGestureService.shared.configure(buddyNode: buddyNode)

            // Try the Mixamo-retargeted mocap idle. If a clip attaches,
            // flag the gesture service so its procedural body-idle layers
            // don't fight the mocap channels. Hair-strand idle, ambient
            // fidgets, blendshape-based face + lip-sync keep running.
            let mocapAttached = BuddyMocapService.shared.play(.default, on: buddyNode, loop: true)
            BuddyGestureService.shared.isMocapDriven = mocapAttached

            print("Loaded buddy in SceneKit: \(buddy.name)")

        } catch {
            print("Failed to load USDZ in SceneKit: \(error)")
        }
    }

    /// Reduces morph targets on nodes that have both skeletal skinning and morphing.
    /// Priority list covers all shapes used by SceneKitLipSyncService and
    /// FacialExpressionService, capped at 20 to stay within Metal's vertex-buffer budget.
    ///
    /// Buddy-specific behaviour on skinned nodes:
    /// - Aleda (DAZ G9): every face mesh is BOTH skinned and shape-keyed. Stripping
    ///   morphers would zero out lip-sync, so we reduce to the priority set instead,
    ///   accepting the Metal vertex-buffer risk in exchange for working lips.
    /// - Others (Micoo etc.): face mesh is typically not skinned, so stripping
    ///   morphers from skinned body nodes remains the safe Micoo-era workaround.
    private func reduceMorphTargets(for node: SCNNode, buddyName: String) {
        let priority: [String] = [
            "jawOpen", "mouthClose", "mouthFunnel", "mouthPucker",
            "mouthSmileLeft", "mouthSmileRight", "mouthFrownLeft", "mouthFrownRight",
            "mouthRollLower", "mouthRollUpper", "mouthPressLeft", "mouthPressRight",
            "mouthLowerDownLeft", "mouthLowerDownRight", "mouthUpperUpLeft", "mouthUpperUpRight",
            "mouthStretchLeft", "mouthStretchRight", "eyeBlinkLeft", "eyeBlinkRight"
        ]

        let keepOnSkinned = buddyName.lowercased().contains("aleda")

        func canonicalShapeName(_ name: String?) -> String? {
            guard var result = name else { return nil }
            while result.last?.isNumber == true {
                result.removeLast()
            }
            return result
        }

        func reduce(_ child: SCNNode, _ morpher: SCNMorpher) {
            guard morpher.targets.count > 20 else { return }

            var kept: [SCNGeometry] = []
            for name in priority {
                if let t = morpher.targets.first(where: { canonicalShapeName($0.name) == name }) {
                    kept.append(t)
                }
            }
            if kept.isEmpty { kept = Array(morpher.targets.prefix(20)) }

            // Original-Morpher behalten und nur die Targets in-place trimmen.
            // Ein frisch erzeugter SCNMorpher verliert die vom USD-Importer gesetzten
            // Normal-Metadaten (faceVarying → vertex), und SceneKit fällt dann auf
            // position-derivierte Normalen zurück → sichtbare Facetten auf Aleda's Haut.
            let prevCount = morpher.targets.count
            morpher.targets = kept

            print("[BuddyPreview] Reduced morpher '\(child.name ?? "?")': \(prevCount)→\(kept.count) targets")
        }

        let faceSubmeshMarkers = [
            "genesis9mouth", "genesis9tear", "genesis9eyes",
            "genesis9eyelashes", "g9eyebrowfibers", "genesis9head",
        ]

        node.enumerateHierarchy { child, _ in
            guard let morpher = child.morpher else { return }

            let nodeName = child.name ?? ""
            let lowerName = nodeName.lowercased()
            let isFaceSubmesh = faceSubmeshMarkers.contains { lowerName.contains($0) }
            let isAledaBody = keepOnSkinned && lowerName.contains("genesis9") && !isFaceSubmesh

            if (child.skinner != nil && !keepOnSkinned) || isAledaBody {
                child.morpher = nil
                print("[BuddyPreview] Removed morpher from '\(nodeName)' (\(morpher.targets.count) targets)")
                return
            }

            reduce(child, morpher)
        }
    }

    private func playAnimations(for node: SCNNode) {
        // Find and play all animations in the scene
        node.enumerateChildNodes { child, _ in
            let keys = child.animationKeys
            if !keys.isEmpty {
                for key in keys {
                    if let player = child.animationPlayer(forKey: key) {
                        player.play()
                    }
                }
            }
        }

        // Also check for animation players on the node itself
        for key in node.animationKeys {
            if let player = node.animationPlayer(forKey: key) {
                player.play()
            }
        }
    }

    private func stopEmbeddedAnimations(for node: SCNNode) {
        node.enumerateHierarchy { child, _ in
            for key in child.animationKeys {
                child.removeAnimation(forKey: key)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject {
        weak var scnView: SCNView?
        var buddyNode: SCNNode?
        var cameraNode: SCNNode?
        var currentModelId: ObjectIdentifier?
        private var arLifecycleObserver: NSObjectProtocol?

        // Original transform for reset
        var originalScale: SCNVector3 = SCNVector3(1, 1, 1)
        var originalRotation: SCNVector4 = SCNVector4(0, 0, 0, 0)
        var originalPosition: SCNVector3 = SCNVector3(0, 0, 0)

        var currentZoom: Float = 1.0

        deinit {
            if let arLifecycleObserver {
                NotificationCenter.default.removeObserver(arLifecycleObserver)
            }
        }

        func startObservingARLifecycle() {
            guard arLifecycleObserver == nil else { return }
            arLifecycleObserver = NotificationCenter.default.addObserver(
                forName: .arBuddyWillEnterAR,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.releasePreviewForAR()
            }
        }

        private func releasePreviewForAR() {
            guard buddyNode != nil || scnView?.scene?.rootNode.childNode(withName: "buddy", recursively: false) != nil else {
                return
            }

            print("[BuddyPreview] Releasing SceneKit buddy before entering AR")
            SceneKitLipSyncService.shared.stopAnimation()
            BuddyMocapService.shared.stopAndFlush(on: buddyNode)
            BuddyGestureService.shared.stopIdle()
            FacialExpressionService.shared.stopIdleBehaviors()
            BuddyFaceBoneService.shared.clear()

            buddyNode?.removeAllActions()
            buddyNode?.removeAllAnimations()
            buddyNode?.removeFromParentNode()
            scnView?.scene?.rootNode.childNode(withName: "buddy", recursively: false)?.removeFromParentNode()
            buddyNode = nil
            currentModelId = nil
            scnView?.isPlaying = false
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let node = buddyNode else { return }

            let translation = gesture.translation(in: gesture.view)

            if gesture.state == .changed {
                // Rotate around Y axis
                let rotationDelta = Float(translation.x) * 0.01
                node.eulerAngles.y += rotationDelta
                gesture.setTranslation(.zero, in: gesture.view)
            }
        }

        @objc func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
            guard let node = buddyNode else { return }

            let translation = gesture.translation(in: gesture.view)

            if gesture.state == .changed {
                let moveSpeed: Float = 0.008
                node.position.x += Float(translation.x) * moveSpeed
                node.position.y -= Float(translation.y) * moveSpeed
                gesture.setTranslation(.zero, in: gesture.view)
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let node = buddyNode else { return }

            switch gesture.state {
            case .began:
                currentZoom = node.scale.x / originalScale.x
            case .changed:
                let newZoom = max(0.5, min(3.0, currentZoom * Float(gesture.scale)))
                let newScale = originalScale.x * newZoom
                node.scale = SCNVector3(newScale, newScale, newScale)
            default:
                break
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let node = buddyNode else { return }

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.3

            node.scale = originalScale
            node.eulerAngles = originalEulerAngles  // Preserve rotation fix
            node.position = originalPosition

            SCNTransaction.commit()

            currentZoom = 1.0
        }

        var originalEulerAngles: SCNVector3 = SCNVector3(0, 0, 0)

        func saveOriginalTransform(_ node: SCNNode) {
            originalScale = node.scale
            originalRotation = node.rotation
            originalEulerAngles = node.eulerAngles  // Save rotation fix
            originalPosition = node.position
            currentZoom = 1.0
        }
    }
}

#Preview {
    BuddyPreviewView(modelEntity: nil, backgroundColor: .systemBackground)
        .frame(height: 400)
}
