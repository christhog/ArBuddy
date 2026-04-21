//
//  ARViewContainer.swift
//  ARBuddy
//
//  Created by Chris Greve on 19.01.26.
//

import SwiftUI
import RealityKit
import ARKit
import Combine

// MARK: - Entity Extension for hierarchy checks
extension Entity {
    /// Checks if this entity is a descendant of the given ancestor
    func isDescendant(of ancestor: Entity) -> Bool {
        var current: Entity? = self.parent
        while let parent = current {
            if parent === ancestor {
                return true
            }
            current = parent.parent
        }
        return false
    }
}

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var viewModel: ARBuddyViewModel

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        // Configure AR Session with horizontal plane detection
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.environmentTexturing = .automatic
        arView.session.run(configuration)

        // Add tap gesture recognizer
        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        arView.addGestureRecognizer(tapGesture)

        // Add pan gesture for globe rotation
        let panGesture = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        arView.addGestureRecognizer(panGesture)

        // Add pinch gesture for globe scaling
        let pinchGesture = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        arView.addGestureRecognizer(pinchGesture)

        // Store reference to arView in coordinator
        context.coordinator.arView = arView

        return arView
    }

    func updateUIView(_ arView: ARView, context: Context) {
        context.coordinator.viewModel = viewModel

        // Handle reset when user taps "Neu platzieren"
        if viewModel.placementMode == .automatic && context.coordinator.isPlaced {
            context.coordinator.reset()
        }

        // Handle automatic placement if no manual position set
        if viewModel.placementMode == .automatic {
            context.coordinator.updateAutomaticPlacement()
        }

        // Handle globe visibility
        if viewModel.isGlobeVisible && !context.coordinator.isGlobeActive {
            context.coordinator.showGlobe()
        } else if !viewModel.isGlobeVisible && context.coordinator.isGlobeActive {
            context.coordinator.hideGlobe()
        }

        // Handle buddy visibility
        context.coordinator.updateBuddyVisibility(viewModel.isBuddyVisible)

        // Handle globe rotation to country
        if let countryCode = viewModel.selectedCountryForRotation {
            context.coordinator.rotateGlobeToCountry(countryCode)
            Task { @MainActor in
                viewModel.selectedCountryForRotation = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject {
        var viewModel: ARBuddyViewModel
        weak var arView: ARView?
        private var currentAnchor: AnchorEntity?
        var isPlaced = false
        private var cancellables = Set<AnyCancellable>()

        // Walking behavior properties
        private var walkTimer: Timer?
        private var currentTarget: SIMD3<Float>?
        private var spawnPosition: SIMD3<Float>?
        private var buddyEntity: ModelEntity?

        // Animation properties
        private var idleAnimation: AnimationResource?
        private var walkingAnimation: AnimationResource?
        private var currentAnimationController: AnimationPlaybackController?
        private var isWalking = false

        // Lip Sync properties
        private var lipSyncConfigured = false

        // Globe properties
        private var globeEntity: Entity?
        private var globeAnchor: AnchorEntity?
        var isGlobeActive = false
        private var lastGlobeRotation: Float = 0
        private var currentGlobeScale: Float = 0.3
        private var isWalkingToGlobe = false

        // Country button overlay properties
        private var buttonUpdateTimer: Timer?

        // Walk parameters from Supabase (with defaults)
        private var walkRadius: Float {
            viewModel.currentBuddy?.walkRadius ?? 1.5
        }
        private var walkSpeed: Float {
            viewModel.currentBuddy?.walkSpeed ?? 0.3
        }

        init(viewModel: ARBuddyViewModel) {
            self.viewModel = viewModel
            super.init()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView = arView else { return }

            let tapLocation = gesture.location(in: arView)

            // If globe is active, check for globe tap first
            if isGlobeActive {
                handleGlobeTap(at: tapLocation)
                return
            }

            // Perform raycast looking for horizontal planes (floor)
            let results = arView.raycast(
                from: tapLocation,
                allowing: .estimatedPlane,
                alignment: .horizontal
            )

            // User tapped - accept any horizontal plane hit
            if let firstResult = results.first {
                let worldPosition = SIMD3<Float>(
                    firstResult.worldTransform.columns.3.x,
                    firstResult.worldTransform.columns.3.y,
                    firstResult.worldTransform.columns.3.z
                )
                placeBuddyAt(worldPosition)
                Task { @MainActor in
                    viewModel.placeAt(worldPosition)
                }
            } else {
                Task { @MainActor in
                    viewModel.setPlacementError("Kein Boden erkannt. Tippe auf eine Bodenfläche.")
                }
            }
        }

        func placeBuddyAt(_ position: SIMD3<Float>) {
            guard let arView = arView else { return }

            // Remove previous anchor if exists
            if let previousAnchor = currentAnchor {
                arView.scene.removeAnchor(previousAnchor)
            }

            // Create new anchor at world position
            let anchor = AnchorEntity(world: position)
            anchor.name = "buddyAnchor"

            // Add buddy model
            if let modelEntity = viewModel.modelEntity {
                let clone = modelEntity.clone(recursive: true)
                // Keep scale from Supabase (already applied in BuddyAssetService)
                clone.position = SIMD3<Float>(0, 0, 0) // Directly on ground

                print("Buddy placed - scale: \(clone.scale), position: \(clone.position)")
                print("Original modelEntity scale: \(modelEntity.scale)")

                anchor.addChild(clone)

                // Store references for walking behavior
                spawnPosition = position
                buddyEntity = clone

                // Play the Mixamo-retargeted mocap idle. Falls back to
                // whatever animation shipped inside the buddy USDZ (e.g.
                // the old bundled walk cycle) if no mocap clip is in the
                // app bundle for this buddy.
                if BuddyMocapService.shared.play(.default, on: clone, loop: true) {
                    print("Mocap idle started")
                } else {
                    idleAnimation = clone.availableAnimations.first
                    if let animation = idleAnimation {
                        currentAnimationController = clone.playAnimation(animation.repeat())
                        print("Fallback idle animation started")
                    } else {
                        print("No idle animation found in model")
                    }
                }

                // Load walking animation, then start walking
                Task {
                    await loadWalkingAnimation()
                    await MainActor.run {
                        startWalking()
                    }

                    // Configure lip sync for this buddy
                    await configureLipSync(for: clone)
                }
            } else {
                // Fallback cube
                let mesh = MeshResource.generateBox(size: 0.1, cornerRadius: 0.005)
                let material = SimpleMaterial(
                    color: UIColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1.0),
                    roughness: 0.15,
                    isMetallic: true
                )
                let fallback = ModelEntity(mesh: mesh, materials: [material])
                fallback.position = SIMD3<Float>(0, 0, 0)
                anchor.addChild(fallback)
            }

            arView.scene.addAnchor(anchor)
            currentAnchor = anchor
            isPlaced = true
        }

        func updateAutomaticPlacement() {
            guard let arView = arView,
                  !isPlaced,
                  viewModel.placementMode == .automatic else { return }

            // Check for detected floor planes at least 2m away
            guard let frame = arView.session.currentFrame else { return }

            for anchor in frame.anchors {
                guard let planeAnchor = anchor as? ARPlaneAnchor,
                      planeAnchor.alignment == .horizontal else {
                    continue
                }

                // Only accept floor classification for automatic placement
                guard planeAnchor.classification == .floor else { continue }

                // Get plane center position
                let planePosition = SIMD3<Float>(
                    planeAnchor.transform.columns.3.x,
                    planeAnchor.transform.columns.3.y,
                    planeAnchor.transform.columns.3.z
                )

                // Calculate horizontal distance from camera (world origin)
                let horizontalDistance = simd_length(SIMD2<Float>(planePosition.x, planePosition.z))

                if horizontalDistance >= 2.0 {
                    // Place buddy automatically
                    placeBuddyAt(planePosition)
                    Task { @MainActor in
                        viewModel.placeAt(planePosition)
                    }
                    break
                }
            }
        }

        func reset() {
            // Stop walking
            walkTimer?.invalidate()
            walkTimer = nil
            currentTarget = nil
            spawnPosition = nil
            buddyEntity = nil
            isWalkingToGlobe = false

            // Stop and clear animations
            currentAnimationController?.stop()
            currentAnimationController = nil
            idleAnimation = nil
            walkingAnimation = nil
            isWalking = false

            // Cleanup lip sync
            lipSyncConfigured = false
            Task { @MainActor in
                LipSyncService.shared.cleanup()
            }

            if let previousAnchor = currentAnchor, let arView = arView {
                arView.scene.removeAnchor(previousAnchor)
            }
            currentAnchor = nil
            isPlaced = false
        }

        // MARK: - Walking Behavior

        func startWalking() {
            print("startWalking called - walkingAnimation available: \(walkingAnimation != nil)")
            pickNewTarget()
            // 60fps update rate for smooth movement (was 20fps/0.05)
            walkTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
                self?.updateWalking()
            }
        }

        func loadWalkingAnimation() async {
            // Debug: List all usdz files in bundle
            if let resourcePath = Bundle.main.resourcePath {
                let fileManager = FileManager.default
                if let files = try? fileManager.contentsOfDirectory(atPath: resourcePath) {
                    let usdzFiles = files.filter { $0.hasSuffix(".usdz") }
                    print("USDZ files in bundle: \(usdzFiles)")
                }
            }

            guard let url = Bundle.main.url(forResource: "Walking_1", withExtension: "usdz") else {
                print("Walking_1.usdz not found in bundle!")
                return
            }

            print("Found Walking_1.usdz at: \(url)")

            do {
                // Load as ModelEntity to get proper skeleton binding
                let animationModel = try await ModelEntity(contentsOf: url)

                print("ModelEntity loaded, available animations: \(animationModel.availableAnimations.count)")

                if let firstAnimation = animationModel.availableAnimations.first {
                    walkingAnimation = firstAnimation
                    print("Walking animation loaded successfully!")
                } else {
                    print("WARNING: No animations found in Walking_1.usdz")
                }
            } catch {
                print("Failed to load walking animation: \(error)")
            }
        }

        func playWalkingAnimation() {
            guard let entity = buddyEntity else {
                print("playWalkingAnimation: No buddy entity")
                return
            }
            guard let animation = walkingAnimation else {
                print("playWalkingAnimation: No walking animation loaded")
                return
            }

            // Keep animation at normal speed (1.0)
            // Adjust walkSpeed in Supabase to match the animation's natural pace
            currentAnimationController?.stop()
            currentAnimationController = entity.playAnimation(
                animation.repeat(),
                transitionDuration: 0.3,  // Smooth transition from idle
                startsPaused: false
            )
            // Animation runs at 1.0x - tune walkSpeed to match
            isWalking = true
            print("Walking animation started")
        }

        func playIdleAnimation() {
            guard let entity = buddyEntity else {
                print("playIdleAnimation: No buddy entity")
                return
            }
            guard let animation = idleAnimation else {
                print("playIdleAnimation: No idle animation")
                return
            }

            currentAnimationController?.stop()
            currentAnimationController = entity.playAnimation(
                animation.repeat(),
                transitionDuration: 0.3,  // Smooth transition from walking
                startsPaused: false
            )
            isWalking = false
            print("Idle animation started")
        }

        func pickNewTarget() {
            guard let spawn = spawnPosition else { return }
            let angle = Float.random(in: 0...(2 * .pi))
            let distance = Float.random(in: 0.5...walkRadius)
            currentTarget = SIMD3<Float>(
                spawn.x + cos(angle) * distance,
                spawn.y,
                spawn.z + sin(angle) * distance
            )
        }

        func updateWalking() {
            guard let entity = buddyEntity,
                  let anchor = currentAnchor else { return }

            // No target means we're pausing (idle)
            guard let target = currentTarget else { return }

            // Get current world position of entity
            let anchorPos = anchor.position(relativeTo: nil)
            let entityLocalPos = entity.position
            let currentWorldPos = SIMD3<Float>(
                anchorPos.x + entityLocalPos.x,
                anchorPos.y + entityLocalPos.y,
                anchorPos.z + entityLocalPos.z
            )

            // Calculate direction to target (horizontal only)
            let direction = SIMD3<Float>(
                target.x - currentWorldPos.x,
                0,
                target.z - currentWorldPos.z
            )
            let distance = simd_length(SIMD2<Float>(direction.x, direction.z))

            // Target reached?
            if distance < 0.1 {
                // Special handling when walking to globe
                if isWalkingToGlobe {
                    isWalkingToGlobe = false
                    stopBuddyWalking()
                    positionBuddyNearGlobe()  // Face the globe
                    print("Buddy reached globe, now facing it")
                    return
                }

                // Normal behavior: play idle and pause before picking new target
                playIdleAnimation()
                currentTarget = nil
                // Random idle duration between 3 and 10 seconds
                let idleDuration = Double.random(in: 3.0...10.0)
                DispatchQueue.main.asyncAfter(deadline: .now() + idleDuration) { [weak self] in
                    guard let self = self else { return }
                    // Don't resume walking if globe is active
                    guard !self.isGlobeActive else { return }
                    self.pickNewTarget()
                    self.playWalkingAnimation()
                }
                return
            }

            // Start walking animation if not already walking
            if !isWalking {
                playWalkingAnimation()
            }

            // Calculate movement step (adjusted for 60fps timer interval)
            let normalized = simd_normalize(direction)
            let step = normalized * walkSpeed * 0.016

            // Update local position (relative to anchor)
            entity.position = SIMD3<Float>(
                entityLocalPos.x + step.x,
                entityLocalPos.y,
                entityLocalPos.z + step.z
            )

            // Rotate to face walking direction
            let angle = atan2(normalized.x, normalized.z)
            entity.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
        }

        // MARK: - Globe Methods

        /// Generates a sphere mesh with equirectangular UV mapping
        /// UV: u = (lon + 180) / 360, v = (90 - lat) / 180
        /// Matches standard world map textures and CountryOverlayGenerator
        private func generateEquirectangularSphere(radius: Float, latSegments: Int = 32, lonSegments: Int = 64) -> MeshResource? {
            var vertices: [SIMD3<Float>] = []
            var normals: [SIMD3<Float>] = []
            var uvs: [SIMD2<Float>] = []
            var indices: [UInt32] = []

            for lat in 0...latSegments {
                let v = Float(lat) / Float(latSegments)  // 0 = north pole, 1 = south pole
                let latAngle = Float.pi / 2 - Float.pi * v  // π/2 to -π/2

                for lon in 0...lonSegments {
                    let u = Float(lon) / Float(lonSegments)  // 0 = -180°, 1 = +180°
                    let lonAngle = Float.pi * 2 * u - Float.pi  // -π to π

                    // Spherical to Cartesian (Home Globe convention: x=sin(lon), z=cos(lon))
                    let x = radius * cos(latAngle) * sin(lonAngle)
                    let y = radius * sin(latAngle)
                    let z = radius * cos(latAngle) * cos(lonAngle)

                    vertices.append(SIMD3<Float>(x, y, z))
                    normals.append(normalize(SIMD3<Float>(x, y, z)))
                    uvs.append(SIMD2<Float>(u, v))
                }
            }

            // Generate triangle indices (counter-clockwise winding for front faces)
            for lat in 0..<latSegments {
                for lon in 0..<lonSegments {
                    let current = UInt32(lat * (lonSegments + 1) + lon)
                    let next = current + UInt32(lonSegments + 1)
                    // Counter-clockwise when viewed from outside the sphere
                    indices.append(contentsOf: [current, current + 1, next])
                    indices.append(contentsOf: [current + 1, next + 1, next])
                }
            }

            var descriptor = MeshDescriptor(name: "equirectangularSphere")
            descriptor.positions = MeshBuffer(vertices)
            descriptor.normals = MeshBuffer(normals)
            descriptor.textureCoordinates = MeshBuffer(uvs)
            descriptor.primitives = .triangles(indices)

            return try? MeshResource.generate(from: [descriptor])
        }

        /// Creates the globe entity - loads Globe.usdz
        func createGlobeEntity() -> Entity {
            guard let loadedEntity = try? Entity.load(named: "Globe") else {
                print("Failed to load Globe.usdz - falling back to procedural mesh")
                return createProceduralGlobe()
            }

            // Debug: Print entity hierarchy
            print("=== GLOBE USDZ DEBUG ===")
            printEntityHierarchy(loadedEntity, indent: 0)

            // Find the actual globe model (skip camera, lights, etc.)
            // Looking for "Political_World_Globe" or any ModelEntity
            let globeModel: Entity
            if let found = findGlobeEntity(in: loadedEntity) {
                globeModel = found
                print("Found globe model: \(found.name ?? "unnamed")")
            } else {
                print("No globe model found, using root entity")
                globeModel = loadedEntity
            }

            // Create a container entity to hold the globe with correct orientation
            let container = Entity()
            container.name = "arGlobe"

            // Clone the globe model and add to container
            let globeClone = globeModel.clone(recursive: true)
            container.addChild(globeClone)

            // Get bounds of the globe model
            let bounds = globeClone.visualBounds(relativeTo: container)
            print("Globe bounds: min=\(bounds.min), max=\(bounds.max), extents=\(bounds.extents)")

            // Scale to desired AR size (0.3m radius = 0.6m diameter)
            let desiredDiameter: Float = 0.6
            let maxExtent = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)

            if maxExtent > 0.001 {
                let scale = desiredDiameter / maxExtent
                container.scale = SIMD3<Float>(repeating: scale)
                print("Scale: \(scale) (from maxExtent: \(maxExtent))")
            } else {
                container.scale = SIMD3<Float>(repeating: 0.3)
                print("WARNING: Bounds were zero, using fallback scale 0.3")
            }

            // USDZ uses Z-up (north pole points +Z), RealityKit uses Y-up
            // Apply -90° X rotation to convert Z-up → Y-up
            globeClone.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            globeClone.position = .zero
            print("Globe child orientation: -90° X rotation (Z-up to Y-up)")

            container.generateCollisionShapes(recursive: true)

            print("Final scale: \(container.scale)")
            print("========================")
            return container
        }

        /// Finds the globe ModelEntity in the USDZ hierarchy
        private func findGlobeEntity(in entity: Entity) -> Entity? {
            // Look for entity with "Globe" or "World" in name, or first ModelEntity
            for child in entity.children {
                let name = child.name.lowercased()
                if name.contains("globe") || name.contains("world") {
                    // If this has a ModelEntity child, return that
                    for subchild in child.children {
                        if subchild is ModelEntity {
                            return subchild
                        }
                    }
                    return child
                }
                // Recurse
                if let found = findGlobeEntity(in: child) {
                    return found
                }
            }
            return nil
        }

        /// Debug helper to print entity hierarchy
        private func printEntityHierarchy(_ entity: Entity, indent: Int) {
            let prefix = String(repeating: "  ", count: indent)
            var info = "\(prefix)\(entity.name ?? "unnamed") [\(type(of: entity))]"

            if let model = entity as? ModelEntity {
                info += " materials: \(model.model?.materials.count ?? 0)"
            }
            print(info)

            for child in entity.children {
                printEntityHierarchy(child, indent: indent + 1)
            }
        }

        /// Fallback: Creates a procedural globe with earth texture and country progress overlay
        private func createProceduralGlobe() -> ModelEntity {
            // Custom sphere with known equirectangular UV mapping
            let sphere: MeshResource
            if let customSphere = generateEquirectangularSphere(radius: 0.3) {
                sphere = customSphere
            } else {
                sphere = MeshResource.generateSphere(radius: 0.3)  // Fallback
            }
            var material = UnlitMaterial()

            // Create combined texture (earth + progress overlay + borders)
            let combinedTexture = createCombinedGlobeTexture()
            if let cgImage = combinedTexture?.cgImage,
               let texture = try? TextureResource.generate(from: cgImage, options: .init(semantic: .color)) {
                material.color = .init(tint: .white, texture: .init(texture))
            } else {
                // Fallback: blue color for ocean
                material.color = .init(tint: UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0))
            }

            let globe = ModelEntity(mesh: sphere, materials: [material])
            globe.name = "arGlobe"
            globe.generateCollisionShapes(recursive: false)
            return globe
        }

        /// Creates a combined texture with earth base + country progress overlay + borders
        func createCombinedGlobeTexture() -> UIImage? {
            // 1. Load base earth texture
            guard let earthImage = UIImage(named: "earth_texture") else {
                print("Failed to load earth_texture")
                return nil
            }

            // 2. Generate progress overlay texture using CountryOverlayGenerator
            let overlayImage = CountryOverlayGenerator.generateOverlayTexture(
                from: viewModel.countryProgress,
                size: CGSize(width: 2048, height: 1024)
            )

            // 3. Combine both textures
            let size = CGSize(width: 2048, height: 1024)
            UIGraphicsBeginImageContextWithOptions(size, false, 1.0)

            // Draw earth base
            earthImage.draw(in: CGRect(origin: .zero, size: size))

            // Draw overlay on top with transparency
            overlayImage?.draw(in: CGRect(origin: .zero, size: size), blendMode: .normal, alpha: 0.8)

            let combined = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()

            return combined
        }

        /// Shows the globe in AR
        func showGlobe() {
            guard let arView = arView, isPlaced, let spawn = spawnPosition else { return }

            // Create globe entity
            let globe = createGlobeEntity()
            globeEntity = globe

            // Position globe in front of buddy (0.5m forward, 1.0m above ground for eye level)
            let globePosition = SIMD3<Float>(spawn.x, spawn.y + 1.0, spawn.z + 0.5)
            let anchor = AnchorEntity(world: globePosition)
            anchor.name = "globeAnchor"
            anchor.addChild(globe)

            arView.scene.addAnchor(anchor)
            globeAnchor = anchor
            isGlobeActive = true

            // Start button position updates
            startButtonUpdateTimer()

            // Move buddy to globe (walking animation)
            moveBuddyToGlobe(globePosition: globePosition)

            print("Globe shown at position: \(globePosition)")
        }

        /// Hides the globe from AR
        func hideGlobe() {
            guard let arView = arView, let anchor = globeAnchor else { return }

            // Stop button position updates
            stopButtonUpdateTimer()

            arView.scene.removeAnchor(anchor)
            globeEntity = nil
            globeAnchor = nil
            isGlobeActive = false
            isWalkingToGlobe = false

            // Resume buddy walking
            if viewModel.isBuddyVisible {
                startWalking()
            }

            print("Globe hidden")
        }

        /// Stops buddy walking and plays idle animation
        func stopBuddyWalking() {
            walkTimer?.invalidate()
            walkTimer = nil
            currentTarget = nil
            playIdleAnimation()
        }

        /// Moves buddy to walk toward the globe position
        func moveBuddyToGlobe(globePosition: SIMD3<Float>) {
            guard let entity = buddyEntity, let anchor = currentAnchor else { return }

            // Target position: 0.5m in front of the globe (on ground level)
            let anchorWorldPos = anchor.position(relativeTo: nil)
            let targetWorldPos = SIMD3<Float>(globePosition.x, anchorWorldPos.y, globePosition.z - 0.5)

            // Set as walking target
            currentTarget = targetWorldPos
            isWalkingToGlobe = true

            // Start walking animation and timer if not already running
            playWalkingAnimation()
            if walkTimer == nil {
                walkTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
                    self?.updateWalking()
                }
            }

            print("Buddy walking to globe at: \(targetWorldPos)")
        }

        /// Positions buddy in front of the globe (called when buddy reaches globe)
        func positionBuddyNearGlobe() {
            guard let entity = buddyEntity,
                  let _ = spawnPosition,
                  let _ = currentAnchor,
                  let globeAnchor = globeAnchor else { return }

            // Rotate buddy to face the globe
            let globeWorldPos = globeAnchor.position(relativeTo: nil)
            let entityWorldPos = entity.position(relativeTo: nil)
            let toGlobe = globeWorldPos - entityWorldPos
            let angle = atan2(toGlobe.x, toGlobe.z)
            entity.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
        }

        /// Updates buddy visibility
        func updateBuddyVisibility(_ visible: Bool) {
            guard let entity = buddyEntity else { return }
            entity.isEnabled = visible

            if visible && !isGlobeActive && walkTimer == nil && isPlaced {
                startWalking()
            } else if !visible {
                stopBuddyWalking()
            }
        }

        /// Rotates the globe animatedly to show the specified country facing the user
        func rotateGlobeToCountry(_ countryCode: String) {
            guard let globe = globeEntity,
                  let arView = arView,
                  let globeAnchor = globeAnchor else { return }

            let (lat, lon) = CountryCenters.center(for: countryCode)

            // 1. Get camera position (user position in AR space)
            guard let cameraTransform = arView.session.currentFrame?.camera.transform else { return }
            let cameraPosition = SIMD3<Float>(
                cameraTransform.columns.3.x,
                cameraTransform.columns.3.y,
                cameraTransform.columns.3.z
            )

            // 2. Get globe position in world space
            let globePosition = globeAnchor.position(relativeTo: nil)

            // 3. Calculate direction from globe to camera (normalized, in world/parent coords)
            let toCamera = cameraPosition - globePosition
            let cameraDir = normalize(SIMD3<Float>(toCamera.x, 0, toCamera.z)) // Keep horizontal (y=0)

            // 4. Convert country lat/lon to radians
            let latRad = Float(lat) * .pi / 180
            let lonRad = Float(lon) * .pi / 180

            // 5. Calculate country position on unrotated globe (local coords)
            // Standard convention: Y = sin(lat), X = -cos(lat)*sin(lon), Z = cos(lat)*cos(lon)
            let countryDir = SIMD3<Float>(
                -cos(latRad) * sin(lonRad),
                sin(latRad),
                cos(latRad) * cos(lonRad)
            )

            // 6. Create Y-axis only rotation (preserve globe's upright orientation)
            // Project both directions to horizontal plane (Y=0)
            let countryHorizontal = normalize(SIMD3<Float>(countryDir.x, 0, countryDir.z))
            let cameraHorizontal = normalize(SIMD3<Float>(cameraDir.x, 0, cameraDir.z))
            let cross = countryHorizontal.x * cameraHorizontal.z - countryHorizontal.z * cameraHorizontal.x
            let dot = countryHorizontal.x * cameraHorizontal.x + countryHorizontal.z * cameraHorizontal.z
            let angle = atan2(cross, dot)
            let targetRotation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))

            // 7. Animate rotation over 1 second
            var transform = globe.transform
            transform.rotation = targetRotation
            globe.move(to: transform, relativeTo: globe.parent, duration: 1.0, timingFunction: .easeInOut)

            print("Rotating globe to \(countryCode) at lat: \(lat), lon: \(lon), cameraDir: \(cameraDir), countryDir: \(countryDir)")
        }

        // MARK: - Globe Gesture Handlers

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let arView = arView, isGlobeActive, let globe = globeEntity else { return }

            let translation = gesture.translation(in: arView)

            switch gesture.state {
            case .changed:
                // Only Y-axis rotation (like a real globe on a stand)
                // This keeps North pole on top and simplifies coordinate mapping
                let yRotation = Float(translation.x) * 0.005

                let deltaY = simd_quatf(angle: yRotation, axis: [0, 1, 0])
                globe.orientation = deltaY * globe.orientation
                gesture.setTranslation(.zero, in: arView)
            default:
                break
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard isGlobeActive, let globe = globeEntity else { return }

            switch gesture.state {
            case .began:
                currentGlobeScale = globe.scale.x
            case .changed:
                // Clamp scale between 0.1 and 1.0
                let newScale = min(max(currentGlobeScale * Float(gesture.scale), 0.1), 1.0)
                globe.scale = SIMD3<Float>(repeating: newScale)
            case .ended:
                currentGlobeScale = globe.scale.x
                // Sync scale with ViewModel
                Task { @MainActor in
                    viewModel.updateGlobeScale(currentGlobeScale)
                }
            default:
                break
            }
        }

        // MARK: - Globe Tap Detection (Country Lookup)

        /// Handles tap on globe to detect country
        func handleGlobeTap(at location: CGPoint) {
            guard let arView = arView, isGlobeActive, let globe = globeEntity else { return }

            // Perform hit test on globe entity
            let hitResults = arView.hitTest(location, query: .nearest, mask: .all)

            for hit in hitResults {
                // Check if hit entity is the globe or any descendant of it
                if hit.entity === globe || hit.entity.isDescendant(of: globe) {
                    // Get the hit position in world coordinates
                    let worldPos = hit.position

                    // Get globe center using visual bounds (same as button positioning)
                    let bounds = globe.visualBounds(relativeTo: nil)
                    let globeCenter = (bounds.min + bounds.max) / 2

                    // Calculate direction from globe center to hit point (in world space)
                    let worldDir = worldPos - globeCenter
                    let worldDirNorm = simd_normalize(worldDir)

                    // Get globe child's full world orientation (includes container + inner rotation)
                    guard let globeChild = globe.children.first else { return }
                    let fullWorldOrientation = globeChild.orientation(relativeTo: nil)

                    // Apply inverse of full orientation to get local direction
                    let localDir = fullWorldOrientation.inverse.act(worldDirNorm)

                    // === COORDINATE DEBUG ===
                    print("=== COORDINATE DEBUG ===")
                    print("worldPos: \(worldPos)")
                    print("globeCenter: \(globeCenter)")
                    print("worldDirNorm: \(worldDirNorm)")
                    print("fullWorldOrientation: \(fullWorldOrientation)")
                    print("localDir: \(localDir)")

                    // Test ALL axis combinations to find correct mapping
                    let latX = asin(Double(localDir.x)) * 180 / .pi
                    let latY = asin(Double(localDir.y)) * 180 / .pi
                    let latZ = asin(Double(localDir.z)) * 180 / .pi

                    print("Lat options: X=\(String(format: "%.1f", latX))° Y=\(String(format: "%.1f", latY))° Z=\(String(format: "%.1f", latZ))°")

                    // Longitude combinations
                    let lonXY = atan2(Double(localDir.x), Double(localDir.y)) * 180 / .pi
                    let lonYX = atan2(Double(localDir.y), Double(localDir.x)) * 180 / .pi
                    let lonXZ = atan2(Double(localDir.x), Double(localDir.z)) * 180 / .pi
                    let lonZX = atan2(Double(localDir.z), Double(localDir.x)) * 180 / .pi
                    let lonYZ = atan2(Double(localDir.y), Double(localDir.z)) * 180 / .pi
                    let lonZY = atan2(Double(localDir.z), Double(localDir.y)) * 180 / .pi
                    let lonNegXY = atan2(Double(-localDir.x), Double(localDir.y)) * 180 / .pi
                    let lonNegXZ = atan2(Double(-localDir.x), Double(localDir.z)) * 180 / .pi
                    let lonXNegZ = atan2(Double(localDir.x), Double(-localDir.z)) * 180 / .pi

                    print("Lon options:")
                    print("  atan2(x,y)=\(String(format: "%.1f", lonXY))° atan2(y,x)=\(String(format: "%.1f", lonYX))°")
                    print("  atan2(x,z)=\(String(format: "%.1f", lonXZ))° atan2(z,x)=\(String(format: "%.1f", lonZX))°")
                    print("  atan2(y,z)=\(String(format: "%.1f", lonYZ))° atan2(z,y)=\(String(format: "%.1f", lonZY))°")
                    print("  atan2(-x,y)=\(String(format: "%.1f", lonNegXY))° atan2(-x,z)=\(String(format: "%.1f", lonNegXZ))° atan2(x,-z)=\(String(format: "%.1f", lonXNegZ))°")
                    print("========================")

                    // localDir is in USDZ native space (Z-up) after fullWorldOrientation.inverse
                    // USDZ Z-up: Z = up (latitude), XY = horizontal plane (longitude)
                    // Use atan2(-x, y) to match the negated X in button positioning (fixes east-west mirroring)
                    // Longitude offset to align USDZ texture with geographic coordinates
                    let longitudeOffset = 10.0  // Adjust if countries still appear misaligned
                    let lat = latZ
                    let lon = lonNegXY + longitudeOffset

                    print("Globe tap at lat: \(lat), lon: \(lon) (raw lonNegXY: \(lonNegXY), offset: +\(longitudeOffset)°)")

                    // Look up country at this position
                    if let countryCode = GeoJSONParser.countryAt(lat: lat, lon: lon) {
                        print("Country found: \(countryCode)")

                        // === COMPARISON DEBUG ===
                        // Compare what tap detection found with what button positioning would calculate
                        if let countryCenter = CountryCenters.centers[countryCode] {
                            let expectedUnit = latLonToLocalPoint(lat: countryCenter.lat, lon: countryCenter.lon, radius: 1.0)
                            print("=== TAP vs BUTTON COMPARISON ===")
                            print("Country: \(countryCode) (lat: \(countryCenter.lat), lon: \(countryCenter.lon))")
                            print("Tap localDir:     \(localDir)")
                            print("Button unitPoint: \(expectedUnit)")
                            print("Difference: x=\(localDir.x - expectedUnit.x), y=\(localDir.y - expectedUnit.y), z=\(localDir.z - expectedUnit.z)")
                            print("================================")
                        }

                        Task { @MainActor in
                            viewModel.selectCountry(countryCode)
                        }
                    } else {
                        print("No country found at this location (ocean?)")
                        Task { @MainActor in
                            viewModel.clearSelectedCountry()
                        }
                    }
                    return
                }
            }
        }

        // MARK: - Country Button Overlay Methods

        /// Converts lat/lon to a 3D point on the globe surface (local coordinates)
        /// Inverse of the tap detection formula: lat = asin(z), lon = atan2(x, y)
        /// Uses USDZ native Z-up coordinate system
        func latLonToLocalPoint(lat: Double, lon: Double, radius: Float = 0.3) -> SIMD3<Float> {
            // Longitude offset to align geographic coordinates with USDZ texture
            // Must match the offset in tap detection!
            let longitudeOffset = 10.0
            let adjustedLon = lon - longitudeOffset

            let latRad = Float(lat) * .pi / 180
            let lonRad = Float(adjustedLon) * .pi / 180

            // USDZ Z-up: Z = up (latitude), XY = horizontal plane (longitude)
            // Inverse of: lat = asin(z), lon = atan2(-x, y)
            // X is negated to fix east-west mirroring (France/Switzerland should be LEFT of Germany)
            let x = -radius * cos(latRad) * sin(lonRad)
            let y = radius * cos(latRad) * cos(lonRad)
            let z = radius * sin(latRad)

            return SIMD3<Float>(x, y, z)
        }

        /// Starts the timer for updating button positions
        func startButtonUpdateTimer() {
            buttonUpdateTimer?.invalidate()
            buttonUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.updateButtonPositions()
            }
        }

        /// Stops the button update timer
        func stopButtonUpdateTimer() {
            buttonUpdateTimer?.invalidate()
            buttonUpdateTimer = nil
            Task { @MainActor in
                viewModel.countryButtons = []
            }
        }

        /// Updates the screen positions of all country buttons
        func updateButtonPositions() {
            guard let globe = globeEntity,
                  let arView = arView,
                  isGlobeActive else { return }

            var buttons: [CountryButton] = []

            // Get the actual globe child entity (has the -90° X rotation applied)
            guard let globeChild = globe.children.first else { return }

            // Use the globe child's full world transformation (includes container + inner rotation)
            let fullWorldOrientation = globeChild.orientation(relativeTo: nil)

            // Get the actual geometric center using visual bounds
            let bounds = globe.visualBounds(relativeTo: nil)
            let globeCenter = (bounds.min + bounds.max) / 2
            let worldRadius = max(bounds.extents.x, bounds.extents.y, bounds.extents.z) / 2

            // Camera position for visibility culling
            let cameraPos = arView.cameraTransform.translation

            // Debug: print once every 2 seconds
            struct DebugTimer { static var lastPrint: Date = .distantPast }
            let now = Date()
            let shouldPrint = now.timeIntervalSince(DebugTimer.lastPrint) > 2.0
            if shouldPrint {
                DebugTimer.lastPrint = now
                print("=== BUTTON DEBUG ===")
                print("Globe entity name: \(globe.name)")
                print("Globe child name: \(globeChild.name)")
                print("Globe child type: \(type(of: globeChild))")
                print("Globe center: \(globeCenter)")
                print("Globe child worldOrientation: \(fullWorldOrientation)")
                print("World radius: \(worldRadius)")
                print("Bounds: min=\(bounds.min), max=\(bounds.max)")

                // Test with Germany
                let testLat = 51.1657
                let testLon = 10.4515
                let testUnit = latLonToLocalPoint(lat: testLat, lon: testLon, radius: 1.0)
                let testRotated = fullWorldOrientation.act(testUnit)
                let testWorld = globeCenter + testRotated * worldRadius
                print("DE unitPoint: \(testUnit)")
                print("DE rotated (full): \(testRotated)")
                print("DE worldPoint: \(testWorld)")
                if let screenPos = arView.project(testWorld) {
                    print("DE screenPos: \(screenPos)")
                }
                print("====================")
            }

            for (code, center) in CountryCenters.centers {
                // 1. Lat/Lon → 3D direction on unit sphere (local coordinates)
                let unitPoint = latLonToLocalPoint(lat: center.lat, lon: center.lon, radius: 1.0)

                // 2. Apply full world orientation (container Y rotation + child -90° X rotation)
                let rotatedDirection = fullWorldOrientation.act(unitPoint)

                // 3. Transform to world coordinates
                let worldPoint = globeCenter + rotatedDirection * worldRadius

                // 4. Culling: Check if point is facing the camera
                let pointToCamera = simd_normalize(cameraPos - worldPoint)
                let dotProduct = simd_dot(rotatedDirection, pointToCamera)
                let isVisible = dotProduct > 0.1  // Slightly above 0 for better edge culling

                // 5. 3D → Screen-Koordinaten
                if isVisible, let screenPos = arView.project(worldPoint) {
                    // Check if within screen bounds
                    let screenBounds = arView.bounds
                    if screenPos.x >= 0 && screenPos.x <= screenBounds.width &&
                       screenPos.y >= 0 && screenPos.y <= screenBounds.height {
                        buttons.append(CountryButton(
                            id: code,
                            screenPosition: screenPos,
                            isVisible: true,
                            clusteredWith: nil
                        ))
                    }
                }
            }

            // Apply clustering using actual world radius for scale reference
            let clustered = clusterNearbyButtons(buttons, globeScale: worldRadius)

            Task { @MainActor in
                viewModel.countryButtons = clustered
            }
        }

        // MARK: - Lip Sync Configuration

        /// Configures lip sync for the placed buddy entity
        func configureLipSync(for entity: ModelEntity) async {
            guard !lipSyncConfigured else { return }

            await viewModel.configureLipSync(for: entity)
            lipSyncConfigured = true

            print("[ARViewContainer] Lip sync configured for buddy")
        }

        /// Calculates minimum distance for clustering based on globe world radius
        func calculateClusterDistance(globeScale: Float) -> CGFloat {
            // Je kleiner der Globe, desto mehr Clustering
            // worldRadius ~0.1 (klein) → 80pt Mindestabstand
            // worldRadius ~0.5 (groß) → 30pt Mindestabstand
            // Linear interpolation: smaller globe = more clustering
            let normalizedScale = min(max((globeScale - 0.1) / 0.4, 0), 1)  // 0.1-0.5 → 0-1
            return CGFloat(80 - (normalizedScale * 50))  // 80pt → 30pt
        }

        /// Clusters buttons that are too close together
        func clusterNearbyButtons(_ buttons: [CountryButton], globeScale: Float) -> [CountryButton] {
            let minDistance = calculateClusterDistance(globeScale: globeScale)
            var result: [CountryButton] = []
            var usedIndices = Set<Int>()

            for i in 0..<buttons.count {
                if usedIndices.contains(i) { continue }

                var cluster = [buttons[i].id]
                var clusterCenter = buttons[i].screenPosition

                // Find all nearby buttons
                for j in (i + 1)..<buttons.count {
                    if usedIndices.contains(j) { continue }

                    let distance = hypot(
                        buttons[j].screenPosition.x - clusterCenter.x,
                        buttons[j].screenPosition.y - clusterCenter.y
                    )

                    if distance < minDistance {
                        cluster.append(buttons[j].id)
                        usedIndices.insert(j)
                        // Update cluster center to average
                        clusterCenter = CGPoint(
                            x: (clusterCenter.x + buttons[j].screenPosition.x) / 2,
                            y: (clusterCenter.y + buttons[j].screenPosition.y) / 2
                        )
                    }
                }

                usedIndices.insert(i)

                if cluster.count > 1 {
                    // Create cluster button
                    result.append(CountryButton(
                        id: cluster[0],  // Use first country as ID
                        screenPosition: clusterCenter,
                        isVisible: true,
                        clusteredWith: Array(cluster.dropFirst())  // Other countries in cluster
                    ))
                } else {
                    // Single button
                    result.append(CountryButton(
                        id: buttons[i].id,
                        screenPosition: buttons[i].screenPosition,
                        isVisible: true,
                        clusteredWith: nil
                    ))
                }
            }

            return result
        }
    }
}
