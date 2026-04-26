//
//  BuddyEyeMakeupService.swift
//  ARBuddy
//
//  Fix for DAZ → USDZ lash export: Blender's UsdPreviewSurface exporter drops
//  the base-color tint that DAZ expects on eyelash materials, so the near-white
//  Aleda_lashes.png reads straight through to diffuseColor and the lashes render
//  hellgrau statt schwarz. Multiplying the material with black zeros the RGB
//  but keeps the alpha mask + per-hair shading intact.
//
//  Also bumps the lash mesh up a notch so Aleda's lashes look a touch fuller —
//  DAZ default lashes are sparse at this resolution.
//
//  Aleda's hair uses textured DAZ strand materials. We tint those at runtime
//  instead of baking a new USDZ, so the reference asset stays untouched.
//

import Foundation
import SceneKit
import UIKit

@MainActor
final class BuddyEyeMakeupService {
    static let shared = BuddyEyeMakeupService()

    private init() {}

    // Per-buddy list of material names that should render as solid black
    // (lashes only, for now). Key is `buddy.name` — same convention as
    // BuddyTintService.skinMaterialNames.
    private static let lashMaterials: [String: Set<String>] = [
        "Aleda": ["Eyelashes_Lower", "Eyelashes_Upper"]
    ]

    private static let hairMaterials: [String: Set<String>] = [
        "Aleda": [
            "Back", "BackUnder", "Bangs1", "Bangs2",
            "Front1", "Front2", "Side1", "Side2"
        ]
    ]

    private static let depthWritingHairMaterials: [String: Set<String>] = [
        "Aleda": ["Bangs1", "Bangs2", "Front1", "Front2"]
    ]

    // Per-buddy uniform scale applied to the lash mesh node so short/sparse
    // DAZ default lashes look a little fuller. Values ≥ 1.0.
    private static let lashScales: [String: Float] = [
        "Aleda": 2.0
    ]

    /// Node-name hints we look for when locating the lash mesh. DAZ G9 uses
    /// `Genesis9Eyelashes` / `Genesis9Eyelashes_Shape` after the USD import.
    private static let lashNodeHints = ["Eyelashes", "Lashes"]

    func apply(to buddyNode: SCNNode, buddyId: String) {
        if let names = Self.lashMaterials[buddyId] {
            buddyNode.enumerateHierarchy { node, _ in
                guard let geometry = node.geometry else { return }
                for material in geometry.materials
                where names.contains(material.name ?? "") {
                    material.multiply.contents = UIColor.black
                    material.multiply.intensity = 1.0
                }
            }
        }

        if let names = Self.hairMaterials[buddyId] {
            let depthWriters = Self.depthWritingHairMaterials[buddyId] ?? []
            buddyNode.enumerateHierarchy { node, _ in
                guard let geometry = node.geometry else { return }
                for material in geometry.materials
                where names.contains(material.name ?? "") {
                    let materialName = material.name ?? ""
                    material.multiply.contents = UIColor.white
                    material.multiply.intensity = 1.0
                    material.isDoubleSided = true
                    material.transparency = 1.0
                    material.transparencyMode = .aOne
                    material.blendMode = .alpha
                    material.writesToDepthBuffer = depthWriters.contains(materialName)
                    material.lightingModel = .physicallyBased
                    material.roughness.contents = 0.72
                    material.specular.intensity = 0.18
                }
            }
        }

        if let scale = Self.lashScales[buddyId],
           let lashRoot = topmostLashNode(in: buddyNode) {
            // Reset to identity first so a second load doesn't compound the
            // scale on top of the previous one.
            lashRoot.scale = SCNVector3(scale, scale, scale)
        }
    }

    private func topmostLashNode(in buddyNode: SCNNode) -> SCNNode? {
        func search(_ node: SCNNode) -> SCNNode? {
            if let name = node.name,
               Self.lashNodeHints.contains(where: { name.contains($0) }) {
                return node
            }
            for child in node.childNodes {
                if let hit = search(child) { return hit }
            }
            return nil
        }
        return search(buddyNode)
    }
}
