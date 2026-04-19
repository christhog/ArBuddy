//
//  GlobeSceneView.swift
//  ARBuddy
//
//  Created by Chris Greve on 18.01.26.
//

import SwiftUI
import SceneKit
import UIKit

/// Controller class to manage globe interactions from SwiftUI
@MainActor
final class GlobeController: @unchecked Sendable {
    private weak var scnView: SCNView?
    private var earthNode: SCNNode?
    private var cameraNode: SCNNode?
    private var rotationAction: SCNAction?
    private var isRotationPaused = true

    /// Called when user interacts with the globe
    var onInteraction: (() -> Void)?

    /// Called when the controller is configured
    var onConfigured: (() -> Void)?

    /// Called when zoom level changes (camera distance from origin)
    var onZoomChanged: ((Float) -> Void)?

    /// Called when user taps on a country
    var onCountryTapped: ((String) -> Void)?

    /// Whether the controller has been configured
    private(set) var isConfigured = false

    /// Default camera distance (zoom level) - slightly closer for better initial view
    private let defaultCameraDistance: Float = 2.4

    /// Zoomed-in camera distance for country focus
    private let focusedCameraDistance: Float = 2.0

    /// Duration of one full rotation in seconds
    private let rotationDuration: TimeInterval = 60

    func configure(scnView: SCNView, earthNode: SCNNode, cameraNode: SCNNode) {
        self.scnView = scnView
        self.earthNode = earthNode
        self.cameraNode = cameraNode

        // Create the rotation action for later use
        let rotation = SCNAction.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: rotationDuration)
        self.rotationAction = SCNAction.repeatForever(rotation)

        isConfigured = true
        onConfigured?()
    }

    /// Center the camera on a specific latitude/longitude coordinate
    /// - Parameters:
    ///   - latitude: Target latitude
    ///   - longitude: Target longitude
    ///   - boundingBox: Optional country bounding box for dynamic zoom calculation
    ///   - animated: Whether to animate the transition
    ///   - duration: Animation duration
    func centerOn(latitude: Double, longitude: Double, boundingBox: CountryBoundingBox? = nil, animated: Bool = false, duration: TimeInterval = 0.5) {
        guard let cameraNode = cameraNode else { return }

        // Convert lat/lon to radians
        // Note: We need to adjust for the earth's tilt and texture mapping
        let latRad = latitude * .pi / 180.0
        let lonRad = longitude * .pi / 180.0

        // Calculate camera distance based on country size
        let distance: Float
        if let box = boundingBox {
            // Larger span = further away, smaller span = closer
            // Small countries (~5° span) → ~1.3 distance
            // Large countries (~50° span) → ~2.5 distance
            distance = Float(1.2 + (box.maxSpan / 60.0))
        } else {
            distance = focusedCameraDistance
        }

        // Position camera to look at the coordinate on the globe surface
        // X = sin(lon) * cos(lat), Y = sin(lat), Z = cos(lon) * cos(lat)
        let position = SCNVector3(
            x: Float(sin(lonRad) * cos(latRad)) * distance,
            y: Float(sin(latRad)) * distance,
            z: Float(cos(lonRad) * cos(latRad)) * distance
        )

        if animated {
            let moveAction = SCNAction.move(to: position, duration: duration)
            moveAction.timingMode = .easeInEaseOut
            cameraNode.runAction(moveAction)

            // Also ensure camera looks at center
            let lookAtAction = SCNAction.customAction(duration: duration) { node, _ in
                node.look(at: SCNVector3(0, 0, 0))
            }
            cameraNode.runAction(lookAtAction)
        } else {
            cameraNode.position = position
            cameraNode.look(at: SCNVector3(0, 0, 0))
        }
    }

    /// Pause the globe rotation
    func pauseRotation() {
        guard let earthNode = earthNode, !isRotationPaused else { return }
        earthNode.removeAllActions()
        isRotationPaused = true
    }

    /// Resume the globe rotation
    func resumeRotation() {
        guard let earthNode = earthNode, let rotationAction = rotationAction, isRotationPaused else { return }
        earthNode.runAction(rotationAction, forKey: "rotation")
        isRotationPaused = false
    }

    /// Animate the camera back to the default view position
    func animateToDefaultView(duration: TimeInterval = 2.5) {
        guard let cameraNode = cameraNode else { return }

        let defaultPosition = SCNVector3(0, 0, defaultCameraDistance)

        let moveAction = SCNAction.move(to: defaultPosition, duration: duration)
        moveAction.timingMode = .easeInEaseOut

        // Also smoothly reset camera orientation
        let lookAtAction = SCNAction.customAction(duration: duration) { node, _ in
            node.look(at: SCNVector3(0, 0, 0))
        }

        cameraNode.runAction(SCNAction.group([moveAction, lookAtAction]))
    }

    /// Report that an interaction occurred
    func reportInteraction() {
        onInteraction?()
    }

    /// Get the current camera distance from origin (zoom level)
    func getCurrentZoomDistance() -> Float {
        guard let cameraNode = cameraNode else { return defaultCameraDistance }
        let pos = cameraNode.position
        return sqrt(pos.x * pos.x + pos.y * pos.y + pos.z * pos.z)
    }

    /// Report the current zoom level change
    func reportZoomChange() {
        let distance = getCurrentZoomDistance()
        onZoomChanged?(distance)
    }
}

/// UIViewRepresentable wrapper for SCNView displaying an interactive 3D globe
struct GlobeSceneView: UIViewRepresentable {
    let countryProgress: [CountryProgress]
    let controller: GlobeController

    init(countryProgress: [CountryProgress], controller: GlobeController) {
        self.countryProgress = countryProgress
        self.controller = controller
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        let (scene, earthNode, cameraNode) = createScene()
        scnView.scene = scene
        scnView.allowsCameraControl = true  // Built-in rotation/zoom via gestures
        scnView.autoenablesDefaultLighting = false
        scnView.backgroundColor = UIColor.clear
        scnView.antialiasingMode = .multisampling4X

        // Configure controller with scene elements
        controller.configure(scnView: scnView, earthNode: earthNode, cameraNode: cameraNode)

        // Store scnView reference in coordinator for hit testing
        context.coordinator.scnView = scnView

        // Add gesture recognizer to detect interactions
        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleGesture(_:)))
        panGesture.delegate = context.coordinator
        scnView.addGestureRecognizer(panGesture)

        let pinchGesture = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleGesture(_:)))
        pinchGesture.delegate = context.coordinator
        scnView.addGestureRecognizer(pinchGesture)

        // Add tap gesture for country selection
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tapGesture.delegate = context.coordinator
        scnView.addGestureRecognizer(tapGesture)

        // Start continuous zoom tracking
        context.coordinator.startZoomTracking()

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // Update the overlay texture when country progress changes
        if let earthNode = uiView.scene?.rootNode.childNode(withName: "earth", recursively: false),
           let material = earthNode.geometry?.firstMaterial {
            material.emission.contents = CountryOverlayGenerator.generateOverlayTexture(
                from: countryProgress,
                size: CGSize(width: 2048, height: 1024)
            )
        }
    }

    private func createScene() -> (SCNScene, SCNNode, SCNNode) {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear

        // Earth sphere
        let sphere = SCNSphere(radius: 1.0)
        sphere.segmentCount = 64

        // Material with earth texture
        let material = SCNMaterial()

        // Use the earth texture from assets, or a fallback color
        if let earthTexture = UIImage(named: "earth_texture") {
            material.diffuse.contents = earthTexture
        } else {
            // Fallback: Ocean blue color
            material.diffuse.contents = UIColor(red: 0.1, green: 0.3, blue: 0.6, alpha: 1.0)
        }

        // Add country progress overlay as emission (glow effect)
        material.emission.contents = CountryOverlayGenerator.generateOverlayTexture(
            from: countryProgress,
            size: CGSize(width: 2048, height: 1024)
        )
        material.emission.intensity = 0.4

        // Subtle specular for water reflection effect
        material.specular.contents = UIColor.white
        material.shininess = 0.1

        sphere.materials = [material]

        let earthNode = SCNNode(geometry: sphere)
        earthNode.name = "earth"

        // Note: Earth tilt removed to ensure correct centering on countries
        // Don't start rotation automatically - controller will manage this
        scene.rootNode.addChildNode(earthNode)

        // Camera
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.1
        cameraNode.camera?.zFar = 100
        cameraNode.position = SCNVector3(0, 0, 3)
        scene.rootNode.addChildNode(cameraNode)

        // Main directional light (sun)
        let sunLight = SCNNode()
        sunLight.light = SCNLight()
        sunLight.light?.type = .directional
        sunLight.light?.intensity = 800
        sunLight.light?.color = UIColor.white
        sunLight.position = SCNVector3(5, 5, 5)
        sunLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(sunLight)

        // Ambient light for the dark side
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 200
        ambientLight.light?.color = UIColor(white: 0.6, alpha: 1.0)
        scene.rootNode.addChildNode(ambientLight)

        return (scene, earthNode, cameraNode)
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let controller: GlobeController
        weak var scnView: SCNView?
        private var displayLink: CADisplayLink?
        private var lastReportedDistance: Float = 0

        init(controller: GlobeController) {
            self.controller = controller
            super.init()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended,
                  let scnView = scnView else { return }

            let location = gesture.location(in: scnView)

            // Hit test on the globe sphere
            let hitResults = scnView.hitTest(location, options: nil)
            guard let hit = hitResults.first(where: { $0.node.name == "earth" }) else { return }

            // Get texture coordinates from hit
            let texCoord = hit.textureCoordinates(withMappingChannel: 0)

            // Convert texture coordinates to lat/lon
            // Texture X: 0 = -180°, 1 = +180°
            // Texture Y: 0 = +90° (north), 1 = -90° (south)
            let lon = Double(texCoord.x) * 360 - 180
            let lat = 90 - Double(texCoord.y) * 180

            // Find country at this coordinate
            if let countryCode = GeoJSONParser.countryAt(lat: lat, lon: lon) {
                Task { @MainActor in
                    controller.onCountryTapped?(countryCode)
                }
            }
        }

        func startZoomTracking() {
            guard displayLink == nil else { return }
            displayLink = CADisplayLink(target: self, selector: #selector(checkZoomLevel))
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30)
            displayLink?.add(to: .main, forMode: .common)
        }

        func stopZoomTracking() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func checkZoomLevel() {
            Task { @MainActor in
                let currentDistance = controller.getCurrentZoomDistance()
                // Only report if distance changed significantly (threshold: 0.05)
                if abs(currentDistance - lastReportedDistance) > 0.05 {
                    lastReportedDistance = currentDistance
                    controller.reportZoomChange()
                }
            }
        }

        @objc func handleGesture(_ gesture: UIGestureRecognizer) {
            if gesture.state == .began || gesture.state == .changed {
                Task { @MainActor in
                    controller.reportInteraction()
                }
            }
        }

        // Allow simultaneous gesture recognition with SceneKit's built-in gestures
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }

        deinit {
            stopZoomTracking()
        }
    }
}

#Preview {
    GlobeSceneView(countryProgress: CountryProgress.sampleData, controller: GlobeController())
        .frame(height: 300)
        .background(Color.black.opacity(0.1))
}
