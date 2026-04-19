//
//  VisemeEvent.swift
//  ARBuddy
//
//  Created by Claude on 15.04.26.
//

import Foundation

// MARK: - Viseme Event

/// Represents a single viseme event from Azure Speech SDK
/// Azure provides 22 standard visemes (0-21) with audio offset timing
struct VisemeEvent: Identifiable, Equatable {
    let id = UUID()
    let visemeId: Int           // 0-21 Azure viseme ID
    let audioOffset: TimeInterval   // Offset in seconds from audio start
    let blendShapes: [String: Float]?  // Optional 55 ARKit blend shapes

    /// Creates a viseme event from Azure SDK callback
    init(visemeId: Int, audioOffsetMilliseconds: Int, blendShapes: [String: Float]? = nil) {
        self.visemeId = visemeId
        self.audioOffset = TimeInterval(audioOffsetMilliseconds) / 1000.0
        self.blendShapes = blendShapes
    }
}

// MARK: - Viseme Queue

/// Manages a queue of viseme events for playback synchronization
class VisemeQueue {
    private var events: [VisemeEvent] = []
    private var currentIndex: Int = 0
    private let lock = NSLock()

    /// Adds viseme events to the queue
    func enqueue(_ events: [VisemeEvent]) {
        lock.lock()
        defer { lock.unlock() }
        self.events.append(contentsOf: events)
        self.events.sort { $0.audioOffset < $1.audioOffset }
    }

    /// Gets the viseme for the current audio time
    /// Returns the most recent viseme that should be active at this time
    func viseme(at audioTime: TimeInterval) -> VisemeEvent? {
        lock.lock()
        defer { lock.unlock() }

        // Find the last viseme with offset <= current time
        var result: VisemeEvent?
        for (index, event) in events.enumerated() {
            if event.audioOffset <= audioTime {
                result = event
                currentIndex = index
            } else {
                break
            }
        }
        return result
    }

    /// Resets the queue for new speech
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        events.removeAll()
        currentIndex = 0
    }

    /// Returns true if queue has events
    var hasEvents: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !events.isEmpty
    }

    /// Returns the total duration (offset of last event)
    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return events.last?.audioOffset ?? 0
    }

    /// Returns true if the current audio time is past the last viseme event (+ small buffer)
    /// Used to detect end-of-speech and close the mouth
    func isPastEnd(at audioTime: TimeInterval, buffer: TimeInterval = 0.02) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = events.last else { return true }
        return audioTime > last.audioOffset + buffer
    }
}

// MARK: - Viseme to Jaw Mapping (Simple fallback)

/// Maps Azure viseme IDs to jaw opening values (0.0 = closed, 1.0 = fully open)
/// Based on IPA phoneme mouth shapes
enum VisemeJawMapping {
    static let jawOpenness: [Int: Float] = [
        0: 0.0,    // Silence
        1: 0.1,    // ae, ax, ah (slightly open)
        2: 0.6,    // aa (open)
        3: 0.4,    // ao (medium open)
        4: 0.3,    // ey, eh, uh (medium)
        5: 0.2,    // er (slightly open)
        6: 0.35,   // y, iy, ih, ix (medium)
        7: 0.3,    // w, uw (rounded)
        8: 0.25,   // ow (medium rounded)
        9: 0.1,    // aw (slightly open)
        10: 0.2,   // oy (medium)
        11: 0.15,  // ay (slightly open)
        12: 0.1,   // h (breath)
        13: 0.0,   // r (closed)
        14: 0.15,  // l (slightly open)
        15: 0.2,   // s, z (teeth visible)
        16: 0.25,  // sh, ch, jh, zh (teeth/lip shape)
        17: 0.1,   // th, dh (tongue between teeth)
        18: 0.2,   // f, v (lower lip to teeth)
        19: 0.1,   // d, t, n, th (tongue to palate)
        20: 0.05,  // k, g, ng (back of mouth)
        21: 0.0    // p, b, m (lips closed)
    ]

    /// Gets jaw openness for a viseme ID
    static func jawOpenness(for visemeId: Int) -> Float {
        jawOpenness[visemeId] ?? 0.0
    }
}

// MARK: - Advanced Viseme to Blend Shapes Mapping

/// Maps Azure viseme IDs to multiple ARKit blend shapes for realistic lip sync
/// Each viseme activates a combination of blend shapes that match the mouth position
enum VisemeBlendShapeMapping {

    /// Returns blend shape weights for a given viseme ID
    /// Values are 0.0-1.0 representing blend shape intensity
    static func blendShapes(for visemeId: Int) -> [String: Float] {
        switch visemeId {
        case 0:
            // Silence - neutral mouth
            return [:]

        case 1:
            // æ, ə, ʌ (cat, about, cup) - relaxed open
            return [
                "jawOpen": 0.25,
                "mouthLowerDownLeft": 0.15,
                "mouthLowerDownRight": 0.15
            ]

        case 2:
            // ɑ (father) - wide open
            return [
                "jawOpen": 0.7,
                "mouthLowerDownLeft": 0.3,
                "mouthLowerDownRight": 0.3,
                "mouthUpperUpLeft": 0.1,
                "mouthUpperUpRight": 0.1
            ]

        case 3:
            // ɔ (dog, all) - rounded open
            return [
                "jawOpen": 0.5,
                "mouthFunnel": 0.3,
                "mouthLowerDownLeft": 0.2,
                "mouthLowerDownRight": 0.2
            ]

        case 4:
            // ɛ, ʊ (bed, put) - medium open
            return [
                "jawOpen": 0.35,
                "mouthStretchLeft": 0.1,
                "mouthStretchRight": 0.1,
                "mouthLowerDownLeft": 0.15,
                "mouthLowerDownRight": 0.15
            ]

        case 5:
            // ɝ (bird) - slightly rounded
            return [
                "jawOpen": 0.2,
                "mouthFunnel": 0.15,
                "mouthPucker": 0.1
            ]

        case 6:
            // i, ɪ (beat, bit) - wide smile shape
            return [
                "jawOpen": 0.15,
                "mouthSmileLeft": 0.4,
                "mouthSmileRight": 0.4,
                "mouthStretchLeft": 0.2,
                "mouthStretchRight": 0.2
            ]

        case 7:
            // u, w (boot, we) - tight pucker
            return [
                "jawOpen": 0.1,
                "mouthPucker": 0.6,
                "mouthFunnel": 0.4
            ]

        case 8:
            // o (boat) - rounded
            return [
                "jawOpen": 0.3,
                "mouthFunnel": 0.5,
                "mouthPucker": 0.3
            ]

        case 9:
            // aʊ (cow) - transitional
            return [
                "jawOpen": 0.4,
                "mouthFunnel": 0.2,
                "mouthLowerDownLeft": 0.2,
                "mouthLowerDownRight": 0.2
            ]

        case 10:
            // ɔɪ (boy) - rounded to spread
            return [
                "jawOpen": 0.35,
                "mouthFunnel": 0.25,
                "mouthSmileLeft": 0.15,
                "mouthSmileRight": 0.15
            ]

        case 11:
            // aɪ (bite) - open to smile
            return [
                "jawOpen": 0.3,
                "mouthSmileLeft": 0.2,
                "mouthSmileRight": 0.2,
                "mouthLowerDownLeft": 0.15,
                "mouthLowerDownRight": 0.15
            ]

        case 12:
            // h (hat) - breath, relaxed open
            return [
                "jawOpen": 0.2,
                "mouthLowerDownLeft": 0.1,
                "mouthLowerDownRight": 0.1
            ]

        case 13:
            // ɹ (red) - slightly rounded
            return [
                "jawOpen": 0.1,
                "mouthPucker": 0.2,
                "mouthFunnel": 0.15
            ]

        case 14:
            // l (led) - tongue visible, open
            return [
                "jawOpen": 0.2,
                "mouthLowerDownLeft": 0.1,
                "mouthLowerDownRight": 0.1,
                "tongueOut": 0.1
            ]

        case 15:
            // s, z (sit, zap) - teeth close, slight smile
            return [
                "jawOpen": 0.05,
                "mouthSmileLeft": 0.25,
                "mouthSmileRight": 0.25,
                "mouthClose": 0.3
            ]

        case 16:
            // ʃ, tʃ, dʒ, ʒ (she, church, judge, measure) - rounded teeth
            return [
                "jawOpen": 0.1,
                "mouthFunnel": 0.35,
                "mouthPucker": 0.2,
                "mouthClose": 0.2
            ]

        case 17:
            // θ, ð (think, that) - tongue between teeth
            return [
                "jawOpen": 0.15,
                "tongueOut": 0.3,
                "mouthLowerDownLeft": 0.05,
                "mouthLowerDownRight": 0.05
            ]

        case 18:
            // f, v (fox, vase) - lower lip to upper teeth
            return [
                "jawOpen": 0.05,
                "mouthRollLower": 0.4,
                "mouthUpperUpLeft": 0.15,
                "mouthUpperUpRight": 0.15
            ]

        case 19:
            // d, t, n (dog, top, not) - tongue to palate
            return [
                "jawOpen": 0.1,
                "mouthClose": 0.2,
                "mouthPressLeft": 0.1,
                "mouthPressRight": 0.1
            ]

        case 20:
            // k, g, ŋ (cat, go, sing) - back of mouth
            return [
                "jawOpen": 0.15,
                "mouthClose": 0.15
            ]

        case 21:
            // p, b, m (pat, bat, mat) - lips pressed together
            return [
                "jawOpen": 0.0,
                "mouthClose": 0.5,
                "mouthPressLeft": 0.4,
                "mouthPressRight": 0.4,
                "mouthPucker": 0.2
            ]

        default:
            return [:]
        }
    }

    /// All blend shape names used in lip sync
    static let allUsedShapes: Set<String> = [
        "jawOpen",
        "mouthClose",
        "mouthFunnel",
        "mouthPucker",
        "mouthSmileLeft",
        "mouthSmileRight",
        "mouthStretchLeft",
        "mouthStretchRight",
        "mouthLowerDownLeft",
        "mouthLowerDownRight",
        "mouthUpperUpLeft",
        "mouthUpperUpRight",
        "mouthRollLower",
        "mouthPressLeft",
        "mouthPressRight",
        "tongueOut"
    ]
}

// MARK: - ARKit Blend Shape Names

/// Standard ARKit face blend shape names for reference
/// Used when model supports blend shapes directly
enum ARKitBlendShapes {
    static let jawOpen = "jawOpen"
    static let jawForward = "jawForward"
    static let jawLeft = "jawLeft"
    static let jawRight = "jawRight"
    static let mouthClose = "mouthClose"
    static let mouthFunnel = "mouthFunnel"
    static let mouthPucker = "mouthPucker"
    static let mouthLeft = "mouthLeft"
    static let mouthRight = "mouthRight"
    static let mouthSmileLeft = "mouthSmileLeft"
    static let mouthSmileRight = "mouthSmileRight"
    static let mouthFrownLeft = "mouthFrownLeft"
    static let mouthFrownRight = "mouthFrownRight"
    static let mouthDimpleLeft = "mouthDimpleLeft"
    static let mouthDimpleRight = "mouthDimpleRight"
    static let mouthStretchLeft = "mouthStretchLeft"
    static let mouthStretchRight = "mouthStretchRight"
    static let mouthRollLower = "mouthRollLower"
    static let mouthRollUpper = "mouthRollUpper"
    static let mouthShrugLower = "mouthShrugLower"
    static let mouthShrugUpper = "mouthShrugUpper"
    static let mouthPressLeft = "mouthPressLeft"
    static let mouthPressRight = "mouthPressRight"
    static let mouthLowerDownLeft = "mouthLowerDownLeft"
    static let mouthLowerDownRight = "mouthLowerDownRight"
    static let mouthUpperUpLeft = "mouthUpperUpLeft"
    static let mouthUpperUpRight = "mouthUpperUpRight"

    /// All mouth-related blend shapes for lip sync
    static let lipSyncShapes: [String] = [
        jawOpen, mouthClose, mouthFunnel, mouthPucker,
        mouthSmileLeft, mouthSmileRight,
        mouthLowerDownLeft, mouthLowerDownRight,
        mouthUpperUpLeft, mouthUpperUpRight
    ]
}
