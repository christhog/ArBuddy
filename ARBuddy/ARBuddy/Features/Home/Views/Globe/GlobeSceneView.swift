//
//  GlobeSceneView.swift
//  ARBuddy
//
//  Created by Chris Greve on 18.01.26.
//

import SwiftUI
import SceneKit
import UIKit

/// UIViewRepresentable wrapper for SCNView displaying an interactive 3D globe
struct GlobeSceneView: UIViewRepresentable {
    let countryProgress: [CountryProgress]

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = createScene()
        scnView.allowsCameraControl = true  // Built-in rotation/zoom via gestures
        scnView.autoenablesDefaultLighting = false
        scnView.backgroundColor = UIColor.clear
        scnView.antialiasingMode = .multisampling4X
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

    private func createScene() -> SCNScene {
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

        // Slight tilt like real Earth (23.5 degrees)
        earthNode.eulerAngles.z = Float(Double.pi / 180.0 * 23.5)

        // Slow continuous rotation
        let rotation = SCNAction.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 60)
        earthNode.runAction(SCNAction.repeatForever(rotation))

        scene.rootNode.addChildNode(earthNode)

        // Camera
        let cameraNode = SCNNode()
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

        return scene
    }
}

#Preview {
    GlobeSceneView(countryProgress: CountryProgress.sampleData)
        .frame(height: 300)
        .background(Color.black.opacity(0.1))
}
