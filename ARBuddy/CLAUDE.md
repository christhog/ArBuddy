# ARBuddy — Project Memory

iOS AR companion app. SwiftUI + SceneKit + RealityKit. Buddies sind USDZ-Modelle aus Blender (Auto-Rig Pro).

## Architektur-Kernpunkte

- `SupabaseService` — Auth + User-State + Buddy-Liste. `AppUser` hat u. a. `selectedBuddyId`, `skinTintHex`.
- `BuddyPreviewView` (SceneKit `UIViewRepresentable`) — lädt das USDZ des aktuell gewählten Buddies, konfiguriert alle Per-Buddy-Services nach dem Load.
- Services unter `ARBuddy/Core/Services/` sind größtenteils `@MainActor`-Singletons (`.shared`) und werden von `BuddyPreviewView` mit der `buddyNode`-Referenz konfiguriert.

## Buddy-Rendering — hart erlernte Fakten

- **Micoo-Weltgröße ≈ 8 m** (`visualHeight` nach Bounding-Box × `buddy.scale`). Alle prozeduralen Translationen müssen deshalb grob 10× so groß sein wie bei einem 1,7-m-Menschen, sonst unsichtbar.
- Micoo hat eingebettete Kamera → `buddyNode.eulerAngles.x = -.pi/2` nötig (Code: `BuddyPreviewView` Zeile ~227).
- **Blender-Bone-Constraints überleben den USDZ-Export NICHT.** In SceneKit ist jeder Bone ein eigenständiges `SCNNode` ohne Constraint-Beziehungen — nur Parent-Child-Hierarchie funktioniert.
  - FK-Controls (`c_arm_fk_l`) drehen → nichts passiert (sind keine Skinning-Bones, Constraints fehlen).
  - Einzelnen Deform-Bone in einer Chain drehen (z. B. `arm_stretch_l`) → Mesh reißt, weil Twist-Geschwister nicht mitgehen.
  - **Lösung:** den Clavicula-Parent drehen (`shoulder_l` / `shoulder_r`) — bewegt den ganzen Arm als Einheit via Hierarchie.
- **Blender 5.1.1 USD-Skel-Export für iOS unbrauchbar:** SceneKit findet weder `SCNAnimation` noch `SCNSkinner` in den exportierten Clips. Baked-Gesture-Pipeline ist dormant (siehe `BuddyGestureService` — Loader returned silently `nil`, `playBaked` fällt auf prozedurale Gesten zurück). Roundtrip über Reality Composer Pro wäre der einzige Weg zurück — aktuell abgewählt.

## Procedural Idle / Gestures — `BuddyGestureService`

- Layered idle via SCNActions mit separaten Action-Keys: `idleBreathKey`, `idleYawKey`, `idleWeightKey`, `idleArmLKey`, `idleArmRKey`.
- Bone-Lookup bevorzugt reine Deform-/Parent-Bones über FK-Controls:
  `shoulder_l/r` (Clavicula) für Armschwung, `arm_stretch_*`/`hand_*`/`thigh_*`/`foot_*` nur für gezielte Gesten.
- `Gesture`-Enum: `nod`, `shakeNo`, `lookLeft`, `lookRight`, `armStretch`, `weightShift`, `headTilt`, `handFidget`, `impatient`, `jump` (head/body-Gesten verifiziert, Arm-Sway via Clavicula).
- Amplituden-Faustregeln bei Micoo-Skala: Atmen ~3 cm Y, Weight-Shift ~10 cm symmetrisch um Ursprung, Arm-Sway ~8° (Clavicula hat weniger ROM als Schulter).

## Skin-Tinting — `BuddyTintService` (DONE)

- Haut umfärben via `material.multiply.contents = UIColor` (NICHT `diffuse.contents` — sonst gehen Poren/Baking verloren). `white` = Identität.
- Hardcodierte Per-Buddy-Material-Liste, z. B. `Micoo: ["Material_001", "Material_002"]`. Fallback-Heuristik: Substring `skin`/`body`/`face`.
- Persistenz: `UserDefaults` (`buddy_tint_<name>`) als Hex + Cloud-Sync via `SupabaseService.updateSkinTint(hex:)` in `users.skin_tint_hex`.
- Live-Refresh aus Settings: Service hält `weak` Referenz auf den aktiven `buddyNode`, Settings-Picker ruft `reapplyPersisted()`.
- UI: `SettingsView` → Section „Buddy-Aussehen" → `SkinTintRow` mit `ColorPicker` + 8 Preset-Swatches (Fitzpatrick I–VI) + „Original wiederherstellen".
- Buddy-Key für die Material-Tabelle ist bewusst `buddy.name` (String), nicht die UUID — robuster für Lookup.

## Hardware-Anforderung

- **Minimum: iPhone 14 (A16 / 6 GB RAM).** Aleda trägt vier 4K-Körpertexturen (≈256 MB VRAM), und beim Buddy-Wechsel entsteht kurz ein Memory-Peak während die neue `SCNScene` geparst wird. Auf 4-GB-Geräten (iPhone 11/12/13-Familie inkl. Pro Max) kickt iOS die App per SIGKILL, sobald das ~1,5–2 GB-Budget überschritten wird.
- **Peak-Mitigation im Swap-Pfad** (`BuddyPreviewView.loadModel`): vor dem async-Load
  - `BuddyMocapService.stopAndFlush(on:)` — killt Clips + leert beide Caches (die `SCNAnimation`s zeigen auf das alte Skeleton).
  - `BuddyGestureService.stopIdle()` + `FacialExpressionService.stopIdleBehaviors()` — stoppen laufende Actions / DisplayLink-Idle.
  - alte `buddyNode.removeFromParentNode()` + `coordinator.buddyNode = nil`.
  - `SCNScene(url:)` läuft anschließend in einem `autoreleasepool`, damit der Parse-Peak sofort wieder freigegeben wird.
- **Keine `UIRequiredDeviceCapabilities`-Enforcement** in Info.plist — App-Store-Installation soll nicht hart blockiert sein, Soft-Hinweis reicht.

## Konventionen

- UserDefaults-Keys nach Muster `<domain>_<detail>` (`selectedBuddyId`, `buddy_tint_<name>`, `azure_sdk_*`).
- Services: `@MainActor final class … { static let shared = …; private init() {} }`.
- Keine Emojis in Code-Files, keine spontanen README/MD-Files ohne explizite Anforderung.
- Deutsch ist primäre Kommunikations- und UI-Sprache (Settings-Labels, Commit-Style spiegelt das teils wider).
