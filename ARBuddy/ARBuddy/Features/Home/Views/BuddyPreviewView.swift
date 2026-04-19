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

        // Remove old buddy node
        scene.rootNode.childNode(withName: "buddy", recursively: false)?.removeFromParentNode()

        // Get the USDZ file URL from the entity
        // We need to load the USDZ directly into SceneKit
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
            let modelScene = try SCNScene(url: url, options: [
                .checkConsistency: true,
                .flattenScene: false
            ])

            // Create container node
            let buddyNode = SCNNode()
            buddyNode.name = "buddy"

            // Check if model has embedded camera (indicates different coordinate system)
            var hasEmbeddedCamera = false
            func checkForCamera(_ node: SCNNode) {
                let name = node.name?.lowercased() ?? ""
                if name.contains("camera") {
                    hasEmbeddedCamera = true
                    return
                }
                for child in node.childNodes {
                    checkForCamera(child)
                    if hasEmbeddedCamera { return }
                }
            }
            checkForCamera(modelScene.rootNode)

            // Add nodes from model scene, filtering out cameras/lights at any level
            func addFilteredChildren(from source: SCNNode, to target: SCNNode) {
                for child in source.childNodes {
                    let name = child.name?.lowercased() ?? ""

                    // Skip embedded cameras, lights, and environment nodes
                    if name.contains("camera") ||
                       name.contains("light") ||
                       name.contains("env_") ||
                       name == "_materials" {
                        continue
                    }

                    let cloned = child.clone()
                    // Recursively filter children of this node too
                    cloned.childNodes.filter { node in
                        let n = node.name?.lowercased() ?? ""
                        return n.contains("camera") || n.contains("light") || n.contains("env_")
                    }.forEach { $0.removeFromParentNode() }

                    target.addChildNode(cloned)
                }
            }
            addFilteredChildren(from: modelScene.rootNode, to: buddyNode)

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

            // Wait one run-loop so SceneKit initialises geometry, then position
            // the node and camera based on the now-correct bounding box.
            let cameraNode = context.coordinator.cameraNode
            let coordinator = context.coordinator
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let (minBound, maxBound) = buddyNode.boundingBox
                let localHeight = (maxBound.y - minBound.y) * scale
                let localDepth  = (maxBound.z - minBound.z) * scale
                let width       = (maxBound.x - minBound.x) * scale

                let visualHeight: Float
                let groundOffset: Float

                if hasEmbeddedCamera {
                    visualHeight = localDepth
                    groundOffset = -minBound.z * scale
                } else {
                    visualHeight = localHeight
                    groundOffset = -minBound.y * scale
                }

                // Place feet at y = 0
                buddyNode.position = SCNVector3(0, groundOffset, 0)
                coordinator.saveOriginalTransform(buddyNode)

                // Camera aimed at face (~85% of model height).
                // Camera is placed lower than the look-at point so it tilts
                // upward — this pushes the face into the upper portion of the
                // screen, clear of the chat overlay at the bottom.
                let faceY      = visualHeight * 0.85
                let fovRadians = Float(50 * Double.pi / 180)
                let frameDim   = max(width, visualHeight * 0.48)
                let distance   = (frameDim / 2) / tan(fovRadians / 2) * 1.3

                // Camera ABOVE face, looking down toward midsection.
                // Because the look-at point is below the face, the face
                // appears in the upper third of the frame — well above the
                // chat overlay that covers the bottom ~45 % of the screen.
                let camY   = faceY * 1.15   // 15 % above face
                let lookAt = faceY * 0.82   // look toward upper chest
                cameraNode?.position = SCNVector3(0, camY, distance)
                cameraNode?.look(at: SCNVector3(0, lookAt, 0))

                print("[BuddyPreview] camY=\(camY) faceY=\(faceY) dist=\(distance) visH=\(visualHeight)")
            }

            // Play animations
            playAnimations(for: buddyNode)

            // Configure SceneKit lip sync service
            SceneKitLipSyncService.shared.configure(buddyNode: buddyNode)

            print("Loaded buddy in SceneKit: \(buddy.name)")

        } catch {
            print("Failed to load USDZ in SceneKit: \(error)")
        }
    }

    private func playAnimations(for node: SCNNode) {
        // Find and play all animations in the scene
        node.enumerateChildNodes { child, _ in
            if let keys = child.animationKeys as? [String], !keys.isEmpty {
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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject {
        weak var scnView: SCNView?
        var buddyNode: SCNNode?
        var cameraNode: SCNNode?
        var currentModelId: ObjectIdentifier?

        // Original transform for reset
        var originalScale: SCNVector3 = SCNVector3(1, 1, 1)
        var originalRotation: SCNVector4 = SCNVector4(0, 0, 0, 0)
        var originalPosition: SCNVector3 = SCNVector3(0, 0, 0)

        var currentZoom: Float = 1.0

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
