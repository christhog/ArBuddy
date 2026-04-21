//
//  BuddyTintService.swift
//  ARBuddy
//
//  Runtime skin-tone tinting for the buddy mesh. We don't replace the baked
//  diffuse texture — we multiply it with a user-chosen color, which preserves
//  pore/shading detail while shifting the overall hue. Persisted per buddy
//  name in UserDefaults.
//

import Foundation
import SceneKit
import UIKit

@MainActor
final class BuddyTintService {
    static let shared = BuddyTintService()

    private init() {}

    // Remembered for live-refresh when the picker changes while Settings is open.
    private weak var activeBuddyNode: SCNNode?
    private var activeBuddyId: String?

    // MARK: - Public API

    /// Applies `tint` (or clears it if nil) to every skin material on `buddyNode`
    /// and remembers the node so subsequent calls can re-tint without a reload.
    func apply(tint: UIColor?, to buddyNode: SCNNode, buddyId: String) {
        activeBuddyNode = buddyNode
        activeBuddyId = buddyId
        let multiplyColor = tint ?? .white  // white = identity (no tint)
        applyToMaterials(buddyNode: buddyNode, buddyId: buddyId, color: multiplyColor)
    }

    /// Reapplies the currently persisted tint to whatever node was last
    /// configured. Safe no-op if no buddy is active.
    func reapplyPersisted() {
        guard let node = activeBuddyNode, let id = activeBuddyId else { return }
        apply(tint: loadPersistedTint(for: id), to: node, buddyId: id)
    }

    func loadPersistedTint(for buddyId: String) -> UIColor? {
        guard let hex = UserDefaults.standard.string(forKey: Self.key(for: buddyId)) else {
            return nil
        }
        return UIColor(hex: hex)
    }

    func savePersistedTint(_ color: UIColor?, for buddyId: String) {
        let key = Self.key(for: buddyId)
        if let color {
            UserDefaults.standard.set(color.hexString, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Debug helper — returns every material name found on the buddy mesh.
    func listMaterials(in buddyNode: SCNNode) -> [String] {
        var names: [String] = []
        buddyNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            for material in geometry.materials {
                names.append(material.name ?? "<unnamed>")
            }
        }
        return names
    }

    // MARK: - Internals

    private func applyToMaterials(buddyNode: SCNNode, buddyId: String, color: UIColor) {
        buddyNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            for material in geometry.materials
            where Self.isSkinMaterial(material.name, buddyId: buddyId) {
                material.multiply.contents = color
                material.multiply.intensity = 1.0
            }
        }
    }

    private static func key(for buddyId: String) -> String {
        "buddy_tint_\(buddyId)"
    }

    // MARK: - Skin Material Identification

    /// Material names that belong to the body/face geometry for each buddy.
    /// Everything else (hair, clothes, eyes, teeth) must stay untouched.
    /// To add a new buddy: temporarily log `listMaterials(in:)` to find the names.
    private static let skinMaterialNames: [String: Set<String>] = [
        "Micoo": ["Material_001", "Material_002"]
    ]

    private static func isSkinMaterial(_ rawName: String?, buddyId: String) -> Bool {
        let name = rawName ?? ""
        if let set = skinMaterialNames[buddyId], set.contains(name) {
            return true
        }
        // Fallback heuristic until the table is populated for this buddy.
        let lower = name.lowercased()
        return lower.contains("skin") || lower.contains("body") || lower.contains("face")
    }
}

// MARK: - Color <-> Hex

extension UIColor {
    /// `#RRGGBB` hex string (alpha dropped — tint is never transparent).
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int((r * 255).rounded())
        let gi = Int((g * 255).rounded())
        let bi = Int((b * 255).rounded())
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }

    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
